const server = "https://api.vibegram.io";
async function run() {
  const res1 = await fetch(`${server}/api/agent-bridge/request`, { method: "POST", headers: {"Content-Type": "application/json"}, body: "{}" });
  const data = await res1.json();
  console.log("request:", data);
  const res2 = await fetch(`${server}/api/agent-bridge/claim`, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ request_id: data.request_id, device_secret: data.device_secret })
  });
  console.log("claim status:", res2.status);
  console.log("claim text:", await res2.text());
}
run();
