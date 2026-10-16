"""End-to-end Retry scenarios on copies of real Recordings, with the Debug build and the fake LLM server.
Usage: TAKKU_E2E_SHORT=<takku_id> TAKKU_E2E_LONG=<takku_id> run.py <scenario> [<scenario>...] | all
Build Debug first (README). Copies the Recordings into runs/ and never touches the real Vault (it aborts if it changes)."""
import datetime, glob, json, os, re, shutil, signal, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
APP = os.path.join(REPO, "build/DerivedData/Build/Products/Debug/Takku.app/Contents/MacOS/Takku")
REAL = os.path.expanduser("~/Library/Application Support/Takku/Recordings")
REAL_VAULT = subprocess.run(["defaults", "read", "app.takku.takku", "vaultPath"], capture_output=True, text=True).stdout.strip()
if not REAL_VAULT or not os.path.isdir(REAL_VAULT):
    raise SystemExit(f"ABORT: the real Vault is not a folder ({REAL_VAULT!r}): cannot check it stays untouched")
PORT = 8765
SERVER_LOG = os.path.join(HERE, "llm-requests.jsonl")
R37 = os.environ["TAKKU_E2E_SHORT"]  # a transcribed Meeting with its audio
R50 = os.environ["TAKKU_E2E_LONG"]  # a longer one, for the chunked Summary


class Run:
    def __init__(self, name, recording):
        self.name, self.id = name, recording
        self.base = os.path.join(HERE, "runs", name)
        shutil.rmtree(self.base, ignore_errors=True)
        self.data = os.path.join(self.base, "Recordings")
        self.vault = os.path.join(self.base, "vault")
        self.folder = os.path.join(self.data, recording)
        os.makedirs(self.vault)
        os.makedirs(self.data)
        subprocess.run(["/bin/cp", "-c", "-R", os.path.join(REAL, recording), self.folder], check=True)
        # The copied record points at the real note: without it the test makes its own note in the test Vault.
        record = os.path.join(self.folder, "processing.json")
        with open(record) as f:
            state = json.load(f)
        state.pop("noteURL", None)
        with open(record, "w") as f:
            json.dump(state, f)
        self.launches = []

    def caches(self):
        return sorted(glob.glob(os.path.join(self.folder, "*.m4a.json")))

    def edit_caches(self, change, names=None):
        for path in self.caches():
            if names is None or os.path.basename(path) in names:
                with open(path) as f:
                    cached = json.load(f)
                change(cached)
                with open(path, "w") as f:
                    json.dump(cached, f)

    def status(self):
        try:
            with open(os.path.join(self.folder, "processing.json")) as f:
                return next(iter(json.load(f)["status"]))
        except Exception:
            return None

    def launch(self, label, mode="transcribe", args=(), llm="/v1", kill_after=None, wait_for=None, timeout=3600):
        outcome = os.path.join(self.base, "smoke-test.txt")
        if os.path.exists(outcome):
            os.remove(outcome)
        before = {p: os.path.getmtime(p) for p in self.caches()}
        argv = [APP, "-vaultPath", self.vault, "-dataDirectory", self.data,
                "-testSummaryBaseURL", f"http://127.0.0.1:{PORT}{llm}", "-openInObsidian", "NO",
                "-useCalendar", "NO", "-suggestCalls", "NO", "-ApplePersistenceIgnoreState", "YES", *args]
        if mode == "transcribe":
            argv += ["-transcribeRecording", self.folder]
        elif mode == "regenerate":
            argv += ["-regenerateMeeting", self.id, "-regenerateTemplate", "Notes"]
        start = time.time()
        log_start = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        process = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        result = None
        while time.time() - start < timeout:
            time.sleep(0.25)
            if kill_after is not None and time.time() - start >= kill_after:
                result = "killed on purpose"
                os.kill(process.pid, signal.SIGKILL)
                break
            if wait_for and wait_for():
                result = f"status {self.status()}"
                break
            if not wait_for and os.path.exists(outcome):
                result = open(outcome).read().strip()
                break
        end = time.time()
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(10)
            except subprocess.TimeoutExpired:
                process.kill()
        touched = [p for p in glob.glob(os.path.join(REAL_VAULT, "**", "*.md"), recursive=True)
                   if os.path.getmtime(p) >= start]
        if touched:
            raise SystemExit(f"ABORT: the real Vault was modified: {touched}")
        time.sleep(2)  # let logd flush
        log = subprocess.run(["/usr/bin/log", "show", "--start", log_start, "--style", "compact", "--info",
                              "--predicate", f'subsystem == "app.takku.takku" AND processID == {process.pid}'],
                             capture_output=True, text=True).stdout
        with open(os.path.join(self.base, f"{label}.log"), "w") as f:
            f.write(log)
        requests = []
        if os.path.exists(SERVER_LOG):
            for line in open(SERVER_LOG):
                r = json.loads(line)
                if start <= r["arrived"] <= end + 1:
                    requests.append(r)
        rewritten = [os.path.basename(p) for p in self.caches() if before.get(p) != os.path.getmtime(p)]
        transcript = os.path.join(self.folder, "transcript.md")
        if os.path.exists(transcript):
            shutil.copy(transcript, os.path.join(self.base, f"{label}-transcript.md"))
        self.launches.append(analyse(label, start, end, result, log, requests, rewritten, len(self.caches())))
        return self.launches[-1]

    def report(self):
        with open(os.path.join(self.base, "report.json"), "w") as f:
            json.dump(self.launches, f, indent=1)
        return {"scenario": self.name, "launches": self.launches}


STAMP = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) \S+ \S+ \[app\.takku\.takku:(\w+)\] (.*)$")


def analyse(label, start, end, result, log, requests, rewritten, caches):
    lines = []
    for line in log.splitlines():
        m = STAMP.match(line)
        if m:
            t = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp()
            lines.append((t, m.group(2), m.group(3)))
    retry_at = next((t for t, _, msg in lines if msg.startswith(("Retry ", "Processing ", "Regeneration "))), start)
    def first(prefix):
        return next((round(t - retry_at, 1) for t, _, msg in lines if prefix in msg), None)
    speakers = first("told apart")  # Also "Speakers not told apart".
    return {
        "launch": label, "outcome": result, "wall_s": round(end - start, 1),
        "app_start_to_retry_s": round(retry_at - start, 1),
        "segments_from_cache": sum(1 for _, _, m in lines if m.endswith(": from the cache")),
        "segments_transcribed": sum(1 for _, _, m in lines if ": transcribing" in m),
        "miss_reasons": sorted({m.split(": transcribing")[1].strip(", ") for _, _, m in lines if ": transcribing" in m}),
        "caches_rewritten": f"{len(rewritten)}/{caches}",
        "whisper_loaded": any("loaded in" in m and "Diarization" not in m for _, _, m in lines),
        "t_segments_ready": first("Segments ready"),
        "t_echo_removed": first("Echo removed"),
        "t_speakers": speakers,
        "t_transcript_ready": first("Transcript ready"),
        "t_first_llm_request_app": first("LLM request"),
        "t_first_llm_arrival_server": round(requests[0]["arrived"] - retry_at, 1) if requests else None,
        "llm_requests": [f'{r["kind"]} {r["status"]} {round(r["replied"] - r["arrived"], 1)}s' for r in requests],
        "t_done": next((round(t - retry_at, 1) for t, _, m in lines
                        if re.match(r"Processing \S+ (completed|failed)", m)), None),
        "timeline": [f"+{round(t - retry_at, 1)}s [{c}] {m}" for t, c, m in lines
                     if "from the cache" not in m],
    }


def scenario(name):
    S = {}

    def s(fn):
        S[fn.__name__] = fn
        return fn

    @s
    def warm_37m():
        """The user's case: Retry on a Meeting already transcribed, all caches valid."""
        r = Run("warm_37m", R37)
        r.launch("retry1")
        r.launch("retry2")
        return r

    @s
    def warm_50m():
        r = Run("warm_50m", R50)
        r.launch("retry1")
        return r

    @s
    def cold_37m():
        """No caches: everything transcribed and diarized; the second Retry must then hit the cache."""
        r = Run("cold_37m", R37)
        for p in r.caches():
            os.remove(p)
        speakers = os.path.join(r.folder, "speakers.json")
        if os.path.exists(speakers):
            os.remove(speakers)
        r.launch("retry_cold")
        r.launch("retry_after")
        return r

    @s
    def other_model():
        """Caches made by another model (as after changing model in Settings)."""
        r = Run("other_model", R37)
        r.edit_caches(lambda c: c.update(model="openai_whisper-small_216MB"))
        r.launch("retry_model_changed")
        r.launch("retry_after")
        return r

    @s
    def languages_changed():
        """Meeting languages changed to English only after the Meeting (cached in Italian)."""
        r = Run("languages_changed", R37)
        r.launch("retry_en_only", args=["-meetingLanguages", "(en)"])
        r.launch("retry_back_to_it")
        return r

    @s
    def languages_superset():
        """Italian and English ticked: the Italian caches stay valid."""
        r = Run("languages_superset", R37)
        r.launch("retry_it_en", args=["-meetingLanguages", "(it, en)"])
        return r

    @s
    def partial_and_corrupt():
        """Two caches missing and two unreadable: only those four transcribed."""
        r = Run("partial_and_corrupt", R37)
        names = [os.path.basename(p) for p in r.caches()]
        for n in names[:2]:
            os.remove(os.path.join(r.folder, n))
        for n in names[8:10]:
            open(os.path.join(r.folder, n), "w").write("{not json")
        r.launch("retry_partial")
        r.launch("retry_after")
        return r

    @s
    def provisional_language():
        """A Segment whose language was detected on too little speech, in English, with it+en ticked."""
        r = Run("provisional_language", R37)
        r.edit_caches(lambda c: c.update(language="en", isLanguageReliable=False), names={"me-007.m4a.json"})
        r.launch("retry_provisional", args=["-meetingLanguages", "(it, en)"])
        r.launch("retry_after", args=["-meetingLanguages", "(it, en)"])
        return r

    @s
    def regeneration():
        """Audio deleted: Retry makes only the Summary from the Transcript in the Vault."""
        r = Run("regeneration", R37)
        r.launch("first_processing")
        for p in glob.glob(os.path.join(r.folder, "*.m4a")):
            os.remove(p)
        r.launch("retry_no_audio", mode="regenerate")
        return r

    @s
    def chunked_summary():
        """Small context: the Summary goes in blocks plus a merge."""
        r = Run("chunked_summary", R50)
        r.launch("retry_8k_context", args=["-testSummaryMaxContextTokens", "8192"])
        return r

    @s
    def slow_and_failing_llm():
        """The provider fails, then answers slowly: the second Retry must not transcribe again."""
        r = Run("slow_and_failing_llm", R37)
        r.launch("retry_llm_fails", llm="/fail/v1")
        r.launch("retry_llm_slow", llm="/delay20/v1")
        return r

    @s
    def killed_mid_retry():
        """Takku quits during the Retry: at the next launch Processing resumes by itself."""
        r = Run("killed_mid_retry", R37)
        r.launch("retry_killed", kill_after=6)
        r.launch("relaunch_resumes", mode="none", wait_for=lambda: r.status() in ("completed", "failed"))
        return r

    return S if name is None else S[name]


if __name__ == "__main__":
    server = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_llm.py"), str(PORT), SERVER_LOG])
    time.sleep(1)
    try:
        names = list(scenario(None)) if sys.argv[1:] == ["all"] else sys.argv[1:]
        for name in names:
            print(f"== {name}", flush=True)
            report = scenario(name)().report()
            for launch in report["launches"]:
                print(json.dumps({k: v for k, v in launch.items() if k != "timeline"}), flush=True)
    finally:
        server.terminate()
