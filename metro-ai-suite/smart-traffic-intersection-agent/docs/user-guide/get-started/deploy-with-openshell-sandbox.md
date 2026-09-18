# Run the Traffic Agent as an OpenShell Sandbox

As an alternative to deploying the traffic-agent as a standard Kubernetes `Deployment`, you can
run it as an OpenShell sandbox. The agent process runs under a Landlock filesystem policy and all
of its egress is forced through OpenShell's L7 proxy, which only permits the endpoints the agent
actually needs. Combined with [Trusted Compute](./deploy-with-trusted-compute-helm.md) and the 
`kata-qemu` runtime class, this adds a second isolation layer: the agent also runs inside its own
hardware-isolated VM with a separate kernel.

## Prerequisites

1. Trusted Compute installed. See [Deploy with Trusted Compute](./deploy-with-trusted-compute-helm.md).
2. Smart Intersection deployed. See the [Smart Intersection Helm Deployment Guide](https://docs.openedgeplatform.intel.com/dev/edge-ai-suites/smart-intersection/get-started/deploy-with-helm.html).

## Step 1: Install and Configure OpenShell

`openshell-setup.sh` installs the agent-sandbox controller, the OpenShell CLI, and the gateway
chart, then registers the gateway with the CLI. It is idempotent, so it is safe to re-run:

If the cluster needs a corporate proxy for egress and it is not already set in your shell,
export it first:

```bash
export https_proxy=http://<host>:<port>
export no_proxy=<comma-separated list>
```

```bash
./chart/openshell-setup.sh install --namespace <your-namespace>

# Example: if the release is deployed in the "smart-intersection" namespace
./chart/openshell-setup.sh install --namespace smart-intersection
```

Edit the configuration block at the top of the script to change any other default, such as the
OpenShell version or the gateway's namespace.

The script leaves a `kubectl port-forward` running in the background; every `openshell` command
needs it. If the gateway pod restarts or the chart is upgraded, its certificates are regenerated
and the forward dies. Re-establish both with:

```bash
./chart/openshell-setup.sh certs --namespace <your-namespace>

# Example: if the release is deployed in the "smart-intersection" namespace
./chart/openshell-setup.sh certs --namespace smart-intersection
```

Confirm the CLI can reach the gateway:

```bash
openshell -g kubernetes status
```

Expect `Status: Connected` and `Authentication: Authenticated (mTLS transport)`.

> **Warning:** The script sets `server.auth.allowUnauthenticatedUsers=true`, which disables user
> authentication and is only appropriate for a trusted local development cluster. The chart's
> mTLS bundle secures the *transport* only — it is **not** user authentication. For anything
> shared, configure OIDC instead; see
> [Access Control](https://docs.nvidia.com/openshell/kubernetes/access-control).

Set the smart-intersection chart's `openshellSandboxNamespace` to the same namespace passed above,
otherwise its NetworkPolicy blocks the agent from the broker's plaintext WebSocket port `1885`.

## Step 2: Deploy the Release and Create the Sandbox

Deploy OVMS and Metrics Manager. With `openshell.enabled=true`:

```bash
helm install stia . -n <your-namespace> \
  --set openshell.enabled=true \
  --set ovms.trustedCompute.enabled=true \
  --set ovms.gpu.enabled=false

# Example: if the release is deployed in the "smart-intersection" namespace
helm install stia . -n smart-intersection \
  --set openshell.enabled=true \
  --set ovms.trustedCompute.enabled=true \
  --set ovms.gpu.enabled=false
```

Then create the sandbox. The script reads OVMS/Metrics Manager/MQTT broker Service DNS and the
VLM settings straight from the release's Helm values:

```bash
export REGISTRY="intel/" TAG="<agent-image-tag>"
./chart/openshell-helm.sh up --namespace <your-namespace>

# Example: if the release is deployed in the "smart-intersection" namespace
./chart/openshell-helm.sh up --namespace smart-intersection
```

Pass `MQTT_HOST=<broker-service>.<broker-namespace>.svc.cluster.local` as an env var if the
broker's Service name/namespace don't match the release's `mqtt.serviceName`/`mqtt.brokerNamespace`
values, or `MQTT_WS_PORT=<port>` if the broker's plaintext WebSocket listener isn't on `1885`.

`REGISTRY` must include the trailing slash. The script refuses `TAG=latest`, because Kubernetes
defaults `imagePullPolicy` to `Always` for `:latest` and OpenShell's `--driver-config-json` does
not accept an `image_pull_policy` override.

The sandbox policy is `chart/openshell-policy.yaml`. The script substitutes the Service addresses
into it and passes it to `sandbox create --policy`, so egress is enforced from the moment the
agent starts. Edit that file to change the filesystem or network rules; the `${...}` placeholders
are filled in by the script and must be left alone. The `weather` block allows `api.weather.gov`,
which needs outbound internet access from the cluster — remove the block to keep the agent on
mock weather data.

## Step 3: Verify

```bash
openshell -g kubernetes --workspace openshell sandbox list
openshell -g kubernetes --workspace openshell policy get stia-traffic-agent --base
kubectl get pod -n <your-namespace> -o jsonpath='{.items[*].spec.runtimeClassName}{"\n"}'

# Example: if the release is deployed in the "smart-intersection" namespace
kubectl get pod -n smart-intersection -o jsonpath='{.items[*].spec.runtimeClassName}{"\n"}'
```

- `sandbox list` should report `Ready`.
- `policy get` should show `Status: Effective` with the `enforcement: enforce` endpoints from
  `chart/openshell-policy.yaml` (broker WebSocket, OVMS REST, Metrics Manager REST, and weather
  REST unless removed), each bound to the `python` binary globs, plus the Landlock
  `read_only`/`read_write` filesystem policy.
- The sandbox pod's `runtimeClassName` should be `kata-qemu`. To confirm the VM is real, compare
  kernels: `kubectl exec <sandbox-pod> -n <your-namespace> -c agent -- uname -r` differs from
  `uname -r` on the host.

The sandbox pod is named `<workspace>--<sandbox>`, that is `openshell--stia-traffic-agent`. The
`<workspace>--` prefix is applied by the gateway and cannot be removed; the script scopes all of
its calls to an OpenShell workspace named `openshell`, which it creates if missing.

The script forwards the API to `http://localhost:8081` and the UI to `http://localhost:7860`.
Both forwards are managed by OpenShell (`openshell forward list`) rather than `kubectl
port-forward`, because the agent listens inside the supervisor's network namespace and is
therefore unreachable from the pod's root namespace.

To remove the sandbox:

```bash
./chart/openshell-helm.sh down --namespace <your-namespace>

# Example: if the release is deployed in the "smart-intersection" namespace
./chart/openshell-helm.sh down --namespace smart-intersection
```

## Clean Up

Remove the sandbox, then the gateway and the copied client secret:

```bash
./chart/openshell-helm.sh down --namespace <your-namespace>
./chart/openshell-setup.sh uninstall --namespace <your-namespace>

# Example: if the release is deployed in the "smart-intersection" namespace
./chart/openshell-helm.sh down --namespace smart-intersection
./chart/openshell-setup.sh uninstall --namespace smart-intersection
```

Neither script removes the OpenShell CLI or its local state. To remove those as well:

```bash
sudo dpkg -r openshell      # or: sudo rpm -e openshell
rm -rf ~/.config/openshell
```

## Learn More

- [OpenShell Documentation](https://docs.nvidia.com/openshell/): Complete OpenShell guide
- [Customize Sandbox Policies](https://docs.nvidia.com/openshell/dev/sandboxes/policies): Policy
  file schema reference
- [Deploy with Trusted Compute](./deploy-with-trusted-compute-helm.md): Run the sandbox inside a
  hardware-isolated VM
