# Compact Menu and Node Certificate Expiry

The top-level menu keeps the running status, current node, proxy toggle, Select Node, Node Speed Test, Subscription, Settings, Tools and Quit. The node list goes under Select Node, editing/updating the subscription under Subscription, routing/chain/system proxy/TUN/launch at login under Settings, and log/exit IP check/config folder/About under Tools. Existing shortcuts and actions are kept.

Every 30-second node check also reads the start and end dates of the TLS leaf certificate, and the speed test window gains an expiry column with an expiry date tooltip. Certificates expiring within 30 days are yellow, and expired or not-yet-valid ones are red; trust/hostname verification failures are marked separately. Diagnosis may read only the certificate dates; it never changes the proxy's certificate verification settings, sends proxy credentials, or marks an untrusted certificate as fine.

REALITY, non-TLS and QUIC protocols are clearly shown as not applicable / not yet supported, and connection failures show "can't confirm". Chain rows summarize the most severe certificate state of the entry and exit. Network checks run in parallel with latency checks, keeping the GUI responsive and batch re-entry protection in place.

Verify time boundaries, SNI, special protocols, certificate read failures and chain summaries; run integration tests against a local TLS server and checks against real nodes; run the actual menu structure diagnostic to confirm every existing action is still reachable; build, install and keep the existing user configuration.
