# ``CodexAppServerRemoteExperimental``

Unsupported research support for the private WHAM controller role.

## Overview

``WHAMController`` claims manual/QR codes, lists paired hosts, creates a protocol-v2 controller transport, and revokes grants stored by an application-provided ``WHAMPairingGrantStore``. Credentials come from ``WHAMCredentialProvider``.

Private relay routes, Biscuit/pairing behavior, and envelopes can change without notice. This product is not re-exported, is excluded from the 0.2.x source-compatibility promise, and should be feature-gated. It never silently probes credentials or persists grants.
