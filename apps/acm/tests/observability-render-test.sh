#!/usr/bin/env bash
# Builds apps/acm/manifests/observability and asserts the two ScrapeConfigs, their agent labels, targets and
# the exported_job deduplication rule; parses the prerequisites policies for registration, placement and the
# inference-only monitors; checks the Redis exporter wiring. Needs kustomize and python3 with PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
kustomize build "$HERE/apps/acm/manifests/observability" > "$T/obs.yaml"
cat > "$T/check.py" <<'END_CHECK'
import sys, yaml
root, built = sys.argv[1], sys.argv[2]
fails = 0; total = 0
def ok(n): global total; total += 1; print(f"   ok   {n}")
def bad(n, why=""): global total, fails; total += 1; fails += 1; print(f"   FAIL {n} {why}")
def check(cond, n, why=""): (ok if cond else bad)(n) if cond else bad(n, why)
docs = [d for d in yaml.safe_load_all(open(built)) if d]
sc = {d["metadata"]["name"]: d for d in docs if d["kind"] == "ScrapeConfig"}
check(set(sc) == {"ai-grid-platform-metrics", "ai-grid-user-workload-metrics"}, "both ScrapeConfigs built", str(set(sc)))
p, u = sc["ai-grid-platform-metrics"], sc["ai-grid-user-workload-metrics"]
check(p["metadata"]["labels"]["app.kubernetes.io/component"] == "platform-metrics-collector", "platform job labelled for the platform agent")
check(u["metadata"]["labels"]["app.kubernetes.io/component"] == "user-workload-metrics-collector", "user-workload job labelled for its agent")
check(p["spec"]["staticConfigs"][0]["targets"] == ["not-configurable"] and p["spec"]["scrapeClass"] == "not-configurable", "platform job leaves target and class to the addon")
check(u["spec"]["staticConfigs"][0]["targets"] == ["prometheus-user-workload.openshift-user-workload-monitoring.svc:9092"] and u["spec"]["scrapeClass"] == "ocp-monitoring", "user-workload job names its target and class")
check(all(d["spec"]["metricsPath"] == "/federate" and d["spec"]["scheme"] == "HTTPS" and d["spec"]["scrapeInterval"] == "30s" for d in sc.values()), "federation over HTTPS every 30 s")
rules = p["spec"].get("metricRelabelings", [])
dedup = [r for r in rules if r.get("action") == "drop" and r.get("sourceLabels") == ["__name__", "exported_job"]]
check(len(dedup) == 1 and "istio_requests_total" in dedup[0]["regex"], "Istio duplicate copies dropped by exported_job")
check(not any("exported_job" not in r.get("sourceLabels", []) and r.get("action") == "drop" for r in rules), "no other drop rule")
mco = [d for d in docs if d["kind"] == "MultiClusterObservability"][0]
check(mco["spec"].get("observabilityAddonSpec") == {} and "interval" not in str(mco["spec"]), "MultiClusterObservability addon settings untouched", str(mco["spec"].get("observabilityAddonSpec")))
reg = list(yaml.safe_load_all(open(f"{root}/apps/rhoai-prerequisites/hub/09-observability-addon-policy.yaml")))
pol = [d for d in reg if d["kind"] == "Policy"][0]
raw = pol["spec"]["policy-templates"][0]["objectDefinition"]["spec"]["object-templates-raw"]
check("complianceType: musthave" in raw and all(n in raw for n in sc) and 'lookup "addon.open-cluster-management.io/v1alpha1"' in raw and "open-cluster-management-global-set" not in raw, "registration lists both ScrapeConfigs under the addon's own placement")
pl = [d for d in reg if d["kind"] == "Placement"][0]; pb = [d for d in reg if d["kind"] == "PlacementBinding"][0]
check(pl["spec"]["predicates"][0]["requiredClusterSelector"]["labelSelector"]["matchLabels"] == {"local-cluster": "true"} and pb["placementRef"]["name"] == pl["metadata"]["name"], "registration bound to the hub only")
mon = list(yaml.safe_load_all(open(f"{root}/apps/rhoai-prerequisites/hub/07-monitoring-policy.yaml")))
raws = {t["objectDefinition"]["metadata"]["name"]: t["objectDefinition"]["spec"]["object-templates-raw"] for t in mon[0]["spec"]["policy-templates"]}
check(set(raws) == {"rhoai-cluster-monitoring", "rhoai-cluster-observability-operator"} and all("lookup" in r for r in raws.values()), "monitoring policy adopts existing objects through lookups (fixtures: apps/rhoai-prerequisites/tests)")
check("fromYAML" in raws["rhoai-cluster-monitoring"] and '"enableUserWorkload" true' in raws["rhoai-cluster-monitoring"] and "retention" not in raws["rhoai-cluster-monitoring"] and "storage" not in raws["rhoai-cluster-monitoring"], "monitoring policy parses the ConfigMap, sets user-workload monitoring and no capacity")
check("cluster-observability-operator" in raws["rhoai-cluster-observability-operator"], "monitoring policy installs the Cluster Observability Operator unless present")
pb7 = list(yaml.safe_load_all(open(f"{root}/apps/rhoai-prerequisites/hub/08-monitoring-placement-binding.yaml")))[0]
check(pb7["placementRef"]["name"] == "rhoai-prerequisites-clusters" and pb7["subjects"][0]["name"] == mon[0]["metadata"]["name"], "monitoring policy bound to every prerequisites cluster")
inf = list(yaml.safe_load_all(open(f"{root}/apps/rhoai-prerequisites/hub/10-gateway-envoy-metrics-policy.yaml")))
ipl = [d for d in inf if d["kind"] == "Placement"][0]; sel = ipl["spec"]["predicates"][0]["requiredClusterSelector"]["labelSelector"]
check(sel["matchLabels"] == {"ai-grid/enabled": "true"} and sel["matchExpressions"][0] == {"key": "ai-grid/role", "operator": "In", "values": ["inference"]}, "role monitors placed on inference-only sites")
tpls = [d for d in inf if d["kind"] == "Policy"][0]["spec"]["policy-templates"]
kinds = sorted(t["objectDefinition"]["kind"] for tpl in tpls for t in tpl["objectDefinition"]["spec"]["object-templates"])
check(kinds == ["PodMonitor", "ServiceMonitor"], "a gateway PodMonitor and an Authorino ServiceMonitor", str(kinds))
check(all(tpl["objectDefinition"]["spec"].get("pruneObjectBehavior") == "DeleteAll" for tpl in tpls), "role monitors are removed when the role changes")
pre = list(yaml.safe_load_all(open(f"{root}/apps/rhoai-prerequisites/hub/03-policy.yaml")))
nps = [t["objectDefinition"] for d in pre if d.get("kind") == "Policy" for tpl in d["spec"]["policy-templates"] for t in tpl["objectDefinition"]["spec"].get("object-templates", []) if t["objectDefinition"]["kind"] == "NetworkPolicy" and t["objectDefinition"]["metadata"]["name"] == "rhoai-collector-metrics"]
froms = nps[0]["spec"]["ingress"][0]["from"] if nps else []
check(len(froms) == 2 and any(f.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name") == "openshift-user-workload-monitoring" and f.get("podSelector", {}).get("matchLabels") == {"app.kubernetes.io/name": "prometheus"} for f in froms), "engines and EPP admit the user-workload Prometheus next to RHOAI's collector")
check('"maas_.*|sar_cache_.*|active_.*|datastore_.*|dns_.*|leader_.*",namespace="redhat-ai-gateway-infra"' in open(f"{root}/apps/acm/manifests/observability/scrapeconfig-ai-grid-user-workload.yaml").read(), "maas-api families bound to their namespace")
rr = yaml.safe_load(open(f"{root}/apps/limitador-redis/manifests/10-redis-replication.yaml"))
pm = yaml.safe_load(open(f"{root}/apps/limitador-redis/manifests/30-redis-exporter-podmonitor.yaml"))
check(rr["spec"]["redisExporter"]["enabled"] is True and "@sha256:" in rr["spec"]["redisExporter"]["image"], "Redis exporter enabled, image pinned by digest")
check(pm["spec"]["selector"]["matchLabels"] == rr["spec"]["affinity"]["podAntiAffinity"]["preferredDuringSchedulingIgnoredDuringExecution"][0]["podAffinityTerm"]["labelSelector"]["matchLabels"], "PodMonitor selects the replication pods")
npol = yaml.safe_load(open(f"{root}/apps/limitador-redis/manifests/03-network-policy.yaml"))
monrule = [r for r in npol["spec"]["ingress"] if any(f.get("namespaceSelector", {}).get("matchLabels", {}).get("network.openshift.io/policy-group") == "monitoring" for f in r["from"])]
check(len(monrule) == 1 and monrule[0]["ports"] == [{"port": 9121, "protocol": "TCP"}], "monitoring admitted on the exporter port only")
for f in ("apps/maas-db/primary/10-primary.yaml", "apps/maas-db/read-clusters/10-read-replica.yaml"):
    d = yaml.safe_load(open(f"{root}/{f}")); check(d["spec"]["monitoring"]["enablePodMonitor"] is True, f"CNPG PodMonitor on {f.split('/')[-2]}")
vals = yaml.safe_load(open(f"{root}/apps/rhoai/values.yaml"))
def ann(path):
    d = vals
    for k in path: d = d[k]
    return yaml.safe_load(d["proxy.istio.io/config"])["proxyStatsMatcher"]["inclusionRegexps"]
serving = ann(["components", "kserve", "gateway", "spec", "infrastructure", "annotations"]) if "kserve" in vals.get("components", {}) else None
try:
    import json
    txt = open(f"{root}/apps/rhoai/values.yaml").read()
    check(txt.count("proxyStatsMatcher") == 2 and txt.count('".*ext_proc.*"') == 2, "Envoy statistics widened on both gateways")
except Exception as e: bad("Envoy statistics widened on both gateways", str(e))
print(f"observability render tests: {total-fails} ok, {fails} failed"); sys.exit(1 if fails else 0)
END_CHECK
python3 "$T/check.py" "$HERE" "$T/obs.yaml"
