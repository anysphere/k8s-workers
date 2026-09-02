# k8s-workers

Helm sample for running Self-Hosted Machines workers on Kubernetes.

Installs an in-cluster `agent worker controller` whose `--spawn` hook
kubectl-creates pool workers as standalone Pods (`restartPolicy: Never`),
optionally with `--warm-idle`. This is an alternative to the published
Kubernetes operator path (`worker-set-controller` / `WorkerDeployment`).

Install docs, values, and the operator comparison live in
[chart/README.md](chart/README.md).

## Related resources

- [Self-Hosted Pool](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool)
- [Deploying with Kubernetes](https://cursor.com/docs/cloud-agent/self-hosted-guides/kubernetes)
- This repo: [`chart/`](chart/), [`scripts/helm-validate.sh`](scripts/helm-validate.sh)

## License

First-party code in this repository is licensed under the **Apache License, Version 2.0** — see [`LICENSE`](LICENSE).

## Trademarks

This license does not grant permission to use the trade names, trademarks, service marks, or product names of SpaceXAI, Anysphere, Cursor, or Grok, except as required for reasonable and customary use in describing the origin of the Work.

Kubernetes is a registered trademark of The Linux Foundation. All other trademarks are the property of their respective owners.

## Disclaimer

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
