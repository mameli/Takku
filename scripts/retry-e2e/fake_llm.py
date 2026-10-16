"""Fake OpenAI-compatible server: logs every request's arrival and reply time as JSON lines.
Behaviour from the base URL path: /v1 normal, /delayN/v1 waits N s, /fail/v1 answers 500."""
import json, re, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        arrived = time.time()
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = body.get("messages", [])
        system = messages[0]["content"] if messages else ""
        user = messages[-1]["content"] if messages else ""
        if system.startswith("Write the title"):
            kind = "title"
        elif "# Transcript" in user:
            kind = "summary"
        else:
            kind = "merge/partial"
        delay = re.search(r"/delay(\d+)/", self.path)
        if delay:
            time.sleep(int(delay.group(1)))
        fail = "/fail/" in self.path
        reply = {"error": {"message": "fake failure"}} if fail else {"choices": [{
            "message": {"content": "Fake title" if kind == "title"
                        else "## Topic\n- A point [00:01]\n\n## Next steps\n- [ ] Something (Me)"},
            "finish_reason": "stop"}]}
        data = json.dumps(reply).encode()
        self.send_response(500 if fail else 200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        with open(LOG, "a") as f:
            f.write(json.dumps({"arrived": arrived, "replied": time.time(), "path": self.path, "kind": kind,
                                "chars": sum(len(m["content"]) for m in messages),
                                "status": 500 if fail else 200}) + "\n")


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
