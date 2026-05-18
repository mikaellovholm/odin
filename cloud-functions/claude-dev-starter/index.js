const functions = require("@google-cloud/functions-framework");
const { InstancesClient } = require("@google-cloud/compute");

const PROJECT = "claude-dev-ml-01";
const ZONE = "europe-north1-a";
const INSTANCE = "claude-dev-vm";

// In-memory rate limit. Cloud Functions can spin up multiple instances under
// load, so this is per-instance — fine for a personal app where the goal is
// preventing accidental loops from running up GCP cost. WINDOW_MS rolling.
const MAX_STARTS_PER_WINDOW = 10;
const WINDOW_MS = 60 * 60 * 1000; // 1 hour
const startTimestamps = [];

const compute = new InstancesClient();

functions.http("claude-dev-starter", async (req, res) => {
  // API key validation
  const apiKey = process.env.API_KEY;
  if (apiKey && req.headers["x-api-key"] !== apiKey) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  try {
    const [instance] = await compute.get({
      project: PROJECT,
      zone: ZONE,
      instance: INSTANCE,
    });

    const vmStatus = instance.status;
    let status;

    if (vmStatus === "RUNNING") {
      status = "running";
    } else if (vmStatus === "TERMINATED" || vmStatus === "STOPPED") {
      // Rate-limit cold starts to cap accidental cost. Reads are unlimited
      // because they don't touch billable compute.
      const now = Date.now();
      while (startTimestamps.length && now - startTimestamps[0] > WINDOW_MS) {
        startTimestamps.shift();
      }
      if (startTimestamps.length >= MAX_STARTS_PER_WINDOW) {
        const oldest = startTimestamps[0];
        const retryAfterSec = Math.ceil((WINDOW_MS - (now - oldest)) / 1000);
        res.set("Retry-After", String(retryAfterSec));
        return res.status(429).json({
          error: "rate_limited",
          message: `Maximum ${MAX_STARTS_PER_WINDOW} VM starts per hour exceeded`,
          retry_after_seconds: retryAfterSec,
        });
      }
      startTimestamps.push(now);

      await compute.start({
        project: PROJECT,
        zone: ZONE,
        instance: INSTANCE,
      });
      status = "started";
    } else {
      // STAGING, PROVISIONING, SUSPENDING, etc.
      status = vmStatus;
    }

    // Get external IP (may be empty if VM is still booting)
    const accessConfigs =
      instance.networkInterfaces?.[0]?.accessConfigs || [];
    const ip = accessConfigs[0]?.natIP || "";

    // Get SSH host key from instance metadata (full OpenSSH format)
    let hostKey = "";
    const metadata = instance.metadata?.items || [];
    const hostKeyEntry = metadata.find(
      (i) => i.key === "ssh-host-key-ed25519"
    );
    if (hostKeyEntry) {
      hostKey = "ssh-ed25519 " + hostKeyEntry.value;
    }

    res.json({ status, ip, hostKey });
  } catch (err) {
    console.error("Error:", err.message);
    res.status(500).json({ error: err.message });
  }
});
