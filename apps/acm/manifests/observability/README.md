# AI Grid metrics collection

Two ScrapeConfigs federate each cluster's Prometheus instances into the hub's
Thanos through the multicluster observability addon:

- `scrapeconfig-ai-grid-platform.yaml`: the platform Prometheus (gateway Envoy
  data plane, container resources, pod state, PVCs, Submariner, CoreDNS, the
  router, node TCP, OVN, API server, the addon's own agents, Thanos on the hub).
- `scrapeconfig-ai-grid-user-workload.yaml`: the user-workload Prometheus
  (grid, MaaS, Limitador, Authorino, Kuadrant, CloudNativePG, MetalLB, EPP and
  engine series; generic Go, process and controller families limited to the
  grid's namespaces).

## Contract with ACM

- A custom ScrapeConfig reaches the managed clusters only when it is listed
  under the addon's `ClusterManagementAddOn` placement configs;
  `apps/rhoai-prerequisites/hub/09-observability-addon-policy.yaml` adds the two
  entries (musthave: the operator's own entries stay).
- The `app.kubernetes.io/component` label picks the agent: platform jobs get
  the addon's placeholder substitution (target and scrape class), user-workload
  jobs are copied verbatim and name their target and scrape class themselves.
- The agents federate without `honor_labels`, so the source job name arrives
  in `exported_job` while `job` carries the ScrapeConfig's own name; the agents'
  remote-write relabeling restores `job` afterwards. Rules that act on the
  source job (the deduplication below) key on `exported_job`.
- `scrapeInterval: 30s` overrides the agents' default of 300 s on these jobs.
  Retention and volumes are not set here.

## Sources per site role

- Where MaaS runs (ingress and combined sites) Kuadrant's `istio-pod-monitor`
  and `kuadrant-authorino-monitor` deliver the gateways' full Envoy statistics
  and Authorino's metrics.
- An inference-only site has RHOAI's `openshift-ai-inference-metrics`
  PodMonitor, which keeps the Istio request families alone;
  `apps/rhoai-prerequisites/hub/10-gateway-envoy-metrics-policy.yaml` adds a
  PodMonitor for the full Envoy statistics and a ServiceMonitor for Authorino
  on those sites only.
- Both gateways carry a `proxy.istio.io/config` annotation
  (`apps/rhoai/values.yaml`) that widens Istio's statistics matcher to the
  ext_proc, ext_authz, rate-limit, wasm and connection families.
- The Istio request families reach the platform Prometheus twice on a MaaS site
  (Kuadrant's monitor and RHOAI's); the platform job drops RHOAI's copy by
  `exported_job`, so one copy per site reaches the hub.

## Exporters

- CloudNativePG: `monitoring.enablePodMonitor` on the primary and the replica
  clusters (`cnpg_*`).
- Limitador's Redis: the operator's exporter sidecar on the replication set,
  image `quay.io/opstree/redis-exporter` v1.44.0 pinned by digest, scraped by
  `apps/limitador-redis/manifests/30-redis-exporter-podmonitor.yaml`; the
  namespace's NetworkPolicy admits the monitoring namespace on port 9121 only.
- User-workload monitoring is switched on and the Cluster Observability
  Operator installed on every site by
  `apps/rhoai-prerequisites/hub/07-monitoring-policy.yaml`. Both adopt what
  exists: `config.yaml` of the `cluster-monitoring-config` ConfigMap is parsed,
  `enableUserWorkload` set and every other key written back; content that does
  not parse or is not a mapping fails the render and nothing is written. An
  operator subscribed anywhere is left to its owner; one all-namespaces
  OperatorGroup in the operator's namespace is reused and a targeted or
  second one fails the render.
- The engines' and schedulers' NetworkPolicy in `03-policy.yaml` admits the
  user-workload Prometheus next to RHOAI's collector on the metrics ports.

## Withdrawal

Removing a ScrapeConfig from Git removes the object, not its entry in the
addon, and the registration policy would put a removed entry back while it
exists. Withdraw in this order: remove (or disable) the registration policy
in Git and confirm it is gone from the hub; edit the `ClusterManagementAddOn`
and drop exactly the `ai-grid-*` entries, leaving the operator's; then remove
the ScrapeConfigs. The role monitors are pruned when a site leaves the
inference-only role.

## Tested with

OpenShift 4.22, ACM 2.17 (multicluster observability addon with
`ScrapeConfig` placement configs), RHOAI 3.6 nightly, three sites (one combined
hub, one inference, one second ingress). Other versions of the addon may differ
in how custom ScrapeConfigs are distributed.

Checks: `apps/acm/tests/observability-render-test.sh`,
`apps/rhoai-prerequisites/tests/monitoring-policy-test.sh`.
