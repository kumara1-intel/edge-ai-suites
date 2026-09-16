# Deploy with Trusted Compute using Helm

This guide provides step-by-step instructions for deploying the Smart Traffic Intersection Agent application with Intel Trusted Compute using Helm on a k3s cluster.

Intel Trusted Compute runs workloads inside hardware-isolated VMs, protecting inference workloads and model data from untrusted co-tenants on the same host.

## Prerequisites

Before you begin, ensure that you have the following prerequisites:

- k3s cluster set up and running.
- Verify that your system meets the [minimum requirements](./system-requirements.md).
  - **Minimum RAM**: 32GB RAM is required for Trusted Compute deployments.
- Helm installed on your system: [Installation Guide](https://helm.sh/docs/intro/install/).
- The cluster must support **dynamic provisioning of Persistent Volumes (PV)**. Refer to the [Kubernetes Dynamic Provisioning Guide](https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/) for more details.
- A running **Smart Intersection** deployment (provides MQTT broker, camera pipelines, and scene analytics).
- The Scenescape CA certificate file (`scenescape-ca.pem`) for TLS connections to the MQTT broker (created during the Smart Intersection installation).
- *(Optional)* A [Hugging Face](https://huggingface.co/) API token if the VLM model requires authentication.
- **Storage Requirement:** The VLM model cache PVC requests 20 GiB by default. Ensure the cluster has sufficient storage available.

**Additional Prerequisites for GPU Deployment:**

- Intel CPU with VT-x and VT-d, integrated GPU, and IOMMU enabled in BIOS/UEFI
- Linux kernel with IOMMU, VFIO, and DRM/i915 or xe driver support

> **Note**: When GPU passthrough is enabled with Trusted Compute, the iGPU is exclusively bound to the Trusted Compute VM and is unavailable to the host or other workloads.

## 1. Install Trusted Compute

Follow the [Trusted Compute baremetal installation guide](https://github.com/open-edge-platform/trusted-compute/blob/main/docs/trusted_compute_baremetal.md) to install Trusted Compute version 1.5.3 or later. Complete the following sections:

1. Prerequisites
2. Download the Trusted Compute Package
3. K3s Option

## 2. Prepare for Deployment

The following steps walk through preparing the Helm chart for deployment. You can install from source code or pull the chart from a registry.

**_Steps 1 to 3 vary depending on whether you prefer to build or pull the Helm chart._**

### Option 1: Install from a Registry

#### Step 1: Pull the Chart

Use the following command to pull the Helm chart:

```bash
helm pull oci://registry-1.docker.io/intel/smart-traffic-intersection-agent --version <version-no>
```

Refer to release notes for details on the latest version to use.

#### Step 2: Extract the `.tgz` File

After pulling the chart, extract the `.tgz` file:

```bash
tar -xvf smart-traffic-intersection-agent-<version-no>.tgz
```

Navigate to the extracted directory:

```bash
cd smart-traffic-intersection-agent
```

#### Step 3: Configure the `values.yaml` File

Edit the `values.yaml` file to set the necessary environment variables. Refer to the [values reference table](./deploy-with-helm.md#valuesyaml-reference).

---

### Option 2: Install from Source

#### Step 1: Clone the Repository

Clone the repository containing the Helm chart:

```bash
# Clone the mainline branch
git clone https://github.com/open-edge-platform/edge-ai-suites.git -b main
```

#### Step 2: Change to the Chart Directory

Navigate to the chart directory:

```bash
cd edge-ai-suites/metro-ai-suite/smart-traffic-intersection-agent/chart
```

#### Step 3: Build Chart Dependencies

The chart uses Helm subcharts for the OVMS model server and the metrics manager. Build them before installing:

```bash
helm dependency build .
```

This downloads/packages the `ovms` and `metrics-manager` subcharts into `chart/charts/*.tgz`,
which Helm requires at render/install time. Re-run this command whenever the subchart sources
under `subcharts/` change.

```bash
helm lint .
```

#### Step 4: Configure the `values.yaml` File

Edit the `values.yaml` file to set the necessary environment variables. Refer to the [values reference table](./deploy-with-helm.md#valuesyaml-reference).

---

### Supported VLM Models

The default model is `OpenVINO/Phi-3.5-vision-instruct-int8-ov`. To use a different model, override it at install time:

```bash
helm install stia . -n <your-namespace> --create-namespace \
  --set ovms.trustedCompute.enabled=true \
  --set ovms.env.modelName=OpenVINO/InternVL2-1B-int4-ov
```

| Model | Structured JSON | Notes |
| --- | --- | --- |
| `OpenVINO/Phi-3.5-vision-instruct-int8-ov` | Good | Default. Pre-converted OpenVINO model; avoids on-cluster Hugging Face export flow. |
| `OpenVINO/InternVL2-1B-int4-ov` | Good | Pre-converted OpenVINO alternative model; avoids on-cluster Hugging Face export flow. |

> **Note:** The OVMS init container downloads and converts the selected model on first startup. Changing the model name requires deleting the existing model cache PVC so the init container re-downloads the new model.

## 3. Deploy the Application

Choose one of the following paths based on whether you need GPU acceleration.

---

### Option A: CPU Deployment

Deploy the Smart Traffic Intersection Agent with Trusted Compute enabled on CPU:

```bash
helm install stia . -n <your-namespace> --create-namespace \
  --set ovms.trustedCompute.enabled=true \
  --set ovms.gpu.enabled=false
```

> **Note:** If the prerequisite **Smart Intersection** deployment is using the GPU or NPU, the GPU is not available for Metrics Manager telemetry in this deployment. Disable GPU telemetry by adding `--set metricsManager.hardware.gpu.enabled=false` to the command above.

---

### Option B: GPU Deployment

#### Step 1: Bind GPU to vfio-pci

> **Note:** Binding the GPU stops the display manager and disables the graphical display on the host. Run this step over SSH. The display is restored after running the `unbind` command.

Use the `intel-igpu-vfio-bind.sh` script from the `tools/` directory of the package installed in [Step 1](#1-install-trusted-compute) to bind the Intel iGPU to the `vfio-pci` driver on each GPU-enabled k3s host.

```bash
sudo ./tools/intel-igpu-vfio-bind.sh bind
```

Verify the GPU is bound correctly:

```bash
lspci -nnk -d 8086: | grep -A 3 "VGA\|Display"
```

The output should show `Kernel driver in use: vfio-pci` for your Intel GPU.

#### Step 2: Deploy with GPU Enabled

```bash
helm install stia . -n <your-namespace> --create-namespace \
  --set ovms.trustedCompute.enabled=true \
  --set ovms.trustedCompute.tc_gpu_enabled=true \
  --set ovms.gpu.enabled=false \
  --set metricsManager.hardware.gpu.enabled=false
```

---

> **Note:** When Trusted Compute is enabled, the OVMS VLM serving service type is automatically set to `ClusterIP` instead of the default `NodePort`. This restricts the model server to in-cluster access only, ensuring the inference endpoint is not externally exposed. To access the OVMS service for debugging, use `kubectl port-forward`.

## 4. Verify Deployment

Verify that the pods are running with the Trusted Compute:

```bash
# Check that OVMS pods are using the trusted compute
kubectl get pods -n <your-namespace> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.runtimeClassName}{"\n"}{end}' | grep ovms

# Verify the pods are running
kubectl get pods -n <your-namespace>

# Check OVMS pod logs to ensure containers started successfully
kubectl logs -n <your-namespace> -l app=stia-ovms-service
```

You should see the OVMS VLM serving pods running with the Trusted Compute.

Wait until all pods show `Running` and `READY 1/1`:

```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=stia -n <your-namespace> --timeout=600s
```

## 5. Access and Verify the Application

Once the pods are ready, access the application. The chart deploys services as `NodePort` by default. Retrieve the allocated ports and node IP:

```bash
# Get the NodePort values
kubectl get svc stia-traffic-agent -n <your-namespace>

# Find the node where the traffic-agent pod is running
kubectl get pod -n <your-namespace> -o wide | grep traffic-agent

# Use the INTERNAL-IP of that node
kubectl get nodes -o wide
```

Then open your browser at:

- **Backend API:** `http://<node-ip>:<backend-node-port>/docs`
- **Gradio UI:** `http://<node-ip>:<ui-node-port>`

### Verify the Application

Follow these verification steps to ensure the application is running correctly:

- Ensure that all pods are running and the services are accessible.
- Access the Gradio UI and verify that it is showing the traffic intersection dashboard.
- Check the backend API at `/docs` for the interactive Swagger documentation.
- Verify that the traffic agent is receiving MQTT messages from Scenescape by checking the logs:

  ```bash
  kubectl logs -l app=stia-traffic-agent -n <your-namespace> -f
  ```

## 6. Run the Traffic Agent as an OpenShell Sandbox

As an alternative to deploying the traffic-agent as a standard Kubernetes `Deployment`,
you can run it as an OpenShell sandbox. This adds a second isolation layer on top of Trusted Compute: the agent process runs
under a Landlock filesystem policy and all of its egress is forced through OpenShell's L7 proxy,
which only permits the three endpoints the agent actually needs. Combined with the `kata-qemu`
runtime class, the agent also runs inside its own hardware-isolated VM with a separate kernel.

### Step 1: Install the Agent Sandbox CRD/Controller

Install the [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) CRD
and controller before installing the OpenShell chart. Check the
[releases page](https://github.com/kubernetes-sigs/agent-sandbox/releases) for the latest
version and update `v1.0.2` below if needed:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.2/sandbox.yaml
kubectl get pods -n agent-sandbox-system
```

### Step 2: Install the OpenShell Gateway

Deploy the OpenShell gateway into the cluster via its Helm chart. Check the
[package listing](https://github.com/NVIDIA/OpenShell/pkgs/container/openshell%2Fhelm-chart)
for the latest version and update `0.0.116` below if needed:

If your cluster requires a corporate proxy for internet egress, configure it on the OpenShell
gateway via `upstreamProxy`, replacing the placeholder values below with your proxy URL and
no-proxy list:

```bash
helm install openshell oci://ghcr.io/nvidia/openshell/helm-chart --version 0.0.116 \
  -n openshell --create-namespace \
  --set server.defaultRuntimeClassName=kata-qemu \
  --set upstreamProxy.url=<your-proxy-url> \       # omit if no corporate proxy is required
  --set upstreamProxy.noProxy=<your-no-proxy-list> # omit if no corporate proxy is required
```

- `server.defaultRuntimeClassName=kata-qemu` makes every sandbox pod run inside a TC VM.

Only `http://` proxy endpoints are supported (TLS `CONNECT` egress through it). See the
[OpenShell Kubernetes setup guide](https://docs.nvidia.com/openshell/kubernetes/setup) and
[Configure a Corporate Upstream Proxy](https://docs.nvidia.com/openshell/kubernetes/setup#configure-a-corporate-upstream-proxy)
for detailed install/upgrade instructions beyond the steps above.

### Step 3: Register the Gateway with the OpenShell CLI

The chart enables mTLS by default, so the CLI needs the generated client bundle to verify the
gateway's certificate over the port-forward:

```bash
mkdir -p ~/.config/openshell/gateways/k8s/mtls
kubectl -n openshell get secret openshell-client-tls -o jsonpath='{.data.ca\.crt}'  | base64 -d > ~/.config/openshell/gateways/k8s/mtls/ca.crt
kubectl -n openshell get secret openshell-client-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/.config/openshell/gateways/k8s/mtls/tls.crt
kubectl -n openshell get secret openshell-client-tls -o jsonpath='{.data.tls\.key}' | base64 -d > ~/.config/openshell/gateways/k8s/mtls/tls.key
```

The sandbox is created through the OpenShell CLI, which needs to reach the gateway:

```bash
kubectl port-forward -n openshell svc/openshell 8080:8080 &
openshell gateway add https://127.0.0.1:8080 --local --name kubernetes
openshell -g kubernetes status
```

Expect `Status: Connected`.

> **Note:** Keep the port-forward alive for `openshell` commands to work. If the gateway pod
> restarts, it dies — just re-run it.

### Step 4: Deploy the Release and Create the Sandbox

Deploy OVMS and Metrics Manager, but leave the traffic-agent Deployment out — the sandbox
replaces it:

```bash
helm install stia . -n <your-namespace> --create-namespace \
  --set openshell.enabled=true \
  --set ovms.trustedCompute.enabled=true \
  --set ovms.gpu.enabled=false
```

Then create the sandbox. The script reads OVMS/Metrics Manager/MQTT broker Service DNS and the
VLM settings straight from the release's Helm values:

```bash
export REGISTRY="intel/" TAG="latest"
./chart/openshell-helm.sh up --namespace <your-namespace>
```

Pass `MQTT_HOST=<broker-service>.<broker-namespace>.svc.cluster.local` as an env var if the
broker's Service name/namespace don't match the release's `mqtt.serviceName`/`mqtt.brokerNamespace`
values, or `MQTT_WS_PORT=<port>` if the broker's plaintext WebSocket listener isn't on `1885`.

`REGISTRY` must match the prefix of the locally built agent image (note the trailing slash);
without it the script falls back to an unqualified image name and the pod lands in
`ImagePullBackOff`.

### Step 5: Verify

```bash
openshell -g kubernetes sandbox list
openshell -g kubernetes policy get <sandbox-name> --base
kubectl get pod -n openshell -o jsonpath='{.items[*].spec.runtimeClassName}{"\n"}'
```

- `sandbox list` should report `Ready`.
- `policy get` should show `Status: Effective` with three `enforcement: enforce` endpoints
  (broker WebSocket, OVMS REST, Metrics Manager REST), each bound to `/usr/local/bin/python`,
  plus the Landlock `read_only`/`read_write` filesystem policy.
- The sandbox pod's `runtimeClassName` should be `kata-qemu`. To confirm the VM is real, compare
  kernels: `kubectl exec <sandbox-pod> -n openshell -c agent -- uname -r` differs from `uname -r`
  on the host.

The script forwards the API to `http://localhost:8081` and the UI to `http://localhost:7860`.
Agent output is written to `chart/.openshell-sandbox-traffic-agent.log`.

To remove the sandbox:

```bash
./chart/openshell-helm.sh down --namespace <your-namespace>
```

## 7. Clean Up Deployment

Follow the steps below in order to cleanly remove the deployment.

**Step 1. Uninstall the Application:**

```bash
helm uninstall stia -n <your-namespace>
```

> **Note:** When `ovms.persistence.keepOnUninstall` is `true` (the default), the VLM model cache PVC is **retained** after uninstall to avoid re-downloading the model. This is recommended during development and testing. To fully clean up all PVCs:
>
> ```bash
> kubectl get pvc -n <your-namespace>
> kubectl delete pvc <pvc-name> -n <your-namespace>
> ```
>
> To have Helm delete the PVC automatically on uninstall, set `ovms.persistence.keepOnUninstall=false` before deploying.

**Step 2. Revert GPU Binding** (if deployed with GPU):

On each k3s host where the GPU was bound, unbind it from vfio-pci:

```bash
sudo ./tools/intel-igpu-vfio-bind.sh unbind
```

This will restore the display manager and graphical display on the host.

**Step 3. Clean Up the Trusted Compute Deployment:**

To uninstall Trusted Compute from the k3s nodes after you have removed the application, refer to the [Trusted Compute documentation](https://github.com/open-edge-platform/trusted-compute/blob/main/docs/trusted_compute_baremetal.md).

**Step 4. Uninstall the OpenShell Gateway** (if deployed with `openshell.enabled=true`):

```bash
./chart/openshell-helm.sh down --namespace <your-namespace>
helm uninstall openshell -n <openshell-namespace>
```

## Troubleshooting

For troubleshooting common deployment issues, refer to the [Troubleshooting section](./deploy-with-helm.md#troubleshooting).

## Learn More

- [Trusted Compute Documentation](https://github.com/open-edge-platform/trusted-compute): Complete guide to Intel Trusted Compute
