const functions = require("@google-cloud/functions-framework");
const { InstancesClient } = require("@google-cloud/compute");

const PROJECT = "claude-dev-ml-01";
const ZONE = "europe-north1-a";
const INSTANCE = "claude-dev-vm";

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
