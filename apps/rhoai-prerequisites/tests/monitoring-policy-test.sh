#!/usr/bin/env bash
# Renders the raw templates of the monitoring and registration policies (extracted from the YAML) against
# lookup fixtures: every `lookup` call is replaced by a map read, so the merge, adoption and placement logic
# runs under helm's template engine (sprig; ACM's fromYAML/toYAML are mapped to helm's). Needs helm and PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0; total=0
ok() { total=$((total+1)); printf '   ok   %-60s\n' "$1"; }; bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %-60s %s\n' "$1" "${2:-}"; }
cat > "$T/extract.py" <<'END_EXTRACT'
import re, sys, yaml, json
# argv: policy file, ConfigurationPolicy name, out file. Writes the raw template with lookups rewritten to map reads.
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Policy"]
raw = None
for d in docs:
    for t in d["spec"]["policy-templates"]:
        o = t["objectDefinition"]
        if o["metadata"]["name"] == sys.argv[2]: raw = o["spec"]["object-templates-raw"]
assert raw, "template not found"
pat = re.compile(r'lookup ("[^"]*") ("[^"]*") (\$\w+|"[^"]*") (\$\w+|"[^"]*")')
raw = pat.sub(lambda m: '(index .Values.lookups (printf "%s|%s|%s|%s" ' + " ".join(m.groups()) + "))", raw)
raw = raw.replace("fromYAML", "fromYaml").replace("toYAML", "toYaml")  # ACM's names for the same sprig-style helpers
open(sys.argv[3], "w").write(raw)
END_EXTRACT
mkdir -p "$T/chart/templates"; printf 'apiVersion: v2\nname: t\nversion: 0.1.0\n' > "$T/chart/Chart.yaml"
printf 'items:\n%s\n' '{{ tpl .Values.src . | indent 2 }}' > "$T/chart/templates/out.yaml"
render() { # template-file fixtures-json -> rendered object-templates (YAML list) or "FAIL: <message>"
  python3 -c 'import json,sys; json.dump({"src": open(sys.argv[1]).read(), "lookups": json.loads(sys.argv[2])}, open(sys.argv[3], "w"))' "$1" "$2" "$T/v.json"
  local out; if out=$(helm template x "$T/chart" -f "$T/v.json" 2>&1); then printf '%s' "$out" | grep -v -E '^(---|# Source:)'; else printf 'FAIL: %s' "$(printf '%s' "$out" | grep -m1 -E 'Error:' | sed -E 's/.*(error calling fail|execution error at \([^)]*\)): //')"; fi; }
cat > "$T/shape.py" <<'END_SHAPE'
import sys, yaml
for i in (yaml.safe_load(sys.stdin) or {}).get("items") or []:
    o = i["objectDefinition"]; k = o["kind"]
    if k == "ConfigMap": print("ConfigMap:" + repr(o["data"]["config.yaml"]))
    elif k == "ClusterManagementAddOn":
        p = o["spec"]["installStrategy"]["placements"][0]
        print("Addon:%s/%s:%s" % (p["name"], p["namespace"], ",".join(c["name"] for c in p["configs"])))
    else: print(k + ":" + o["metadata"].get("namespace", "") + "/" + o["metadata"]["name"])
END_SHAPE
shape() { python3 "$T/shape.py" 2>/dev/null; }
t() { # name want template fixtures
  local name=$1 want=$2 tpl=$3 fx=$4 got; got=$(render "$tpl" "$fx"); case "$got" in FAIL:*) ;; *) got=$(printf '%s' "$got" | shape | tr '\n' ' ');; esac
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name" "got: $got"; fi; }
P=$HERE/../hub/07-monitoring-policy.yaml; R=$HERE/../hub/09-observability-addon-policy.yaml
python3 "$T/extract.py" "$P" rhoai-cluster-monitoring "$T/cm.tpl"; python3 "$T/extract.py" "$P" rhoai-cluster-observability-operator "$T/coo.tpl"; python3 "$T/extract.py" "$R" rhoai-observability-addon-scrapeconfigs "$T/reg.tpl"
CM='v1|ConfigMap|openshift-monitoring|cluster-monitoring-config'
cat > "$T/cmshape.py" <<'END_CMSHAPE'
import sys, yaml
items = (yaml.safe_load(sys.stdin) or {}).get("items") or []
cfg = yaml.safe_load(items[0]["objectDefinition"]["data"]["config.yaml"])
print("ConfigMap:" + yaml.safe_dump(cfg, sort_keys=True, default_flow_style=False).replace("\n", " ").strip())
END_CMSHAPE
c() { # name want fixtures: the ConfigMap's config.yaml parsed and re-dumped sorted, so formatting differences do not matter
  local name=$1 want=$2 fx=$3 got; got=$(render "$T/cm.tpl" "$fx"); case "$got" in FAIL:*) ;; *) got=$(printf '%s' "$got" | python3 "$T/cmshape.py" 2>/dev/null);; esac
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name" "got: $got"; fi; }
c "no ConfigMap: created with user-workload on" "ConfigMap:enableUserWorkload: true" '{}'
c "existing settings preserved" "ConfigMap:enableUserWorkload: true prometheusK8s:   retention: 15d" "{\"$CM\": {\"data\": {\"config.yaml\": \"prometheusK8s:\\n  retention: 15d\\n\"}}}"
c "already on: unchanged" "ConfigMap:alertmanagerMain: {} enableUserWorkload: true" "{\"$CM\": {\"data\": {\"config.yaml\": \"alertmanagerMain: {}\\nenableUserWorkload: true\\n\"}}}"
c "off: corrected, rest kept" "ConfigMap:enableUserWorkload: true prometheusK8s:   retention: 7d" "{\"$CM\": {\"data\": {\"config.yaml\": \"enableUserWorkload: false\\nprometheusK8s:\\n  retention: 7d\\n\"}}}"
c "off with extra spaces: corrected" "ConfigMap:enableUserWorkload: true" "{\"$CM\": {\"data\": {\"config.yaml\": \"enableUserWorkload:    false\\n\"}}}"
c "commented key: real key set, comment irrelevant" "ConfigMap:enableUserWorkload: true prometheusK8s:   retention: 7d" "{\"$CM\": {\"data\": {\"config.yaml\": \"# enableUserWorkload: true\\nprometheusK8s:\\n  retention: 7d\\n\"}}}"
c "flow-style mapping: parsed, not corrupted" "ConfigMap:enableUserWorkload: true prometheusK8s:   retention: 7d" "{\"$CM\": {\"data\": {\"config.yaml\": \"{prometheusK8s: {retention: 7d}}\"}}}"
c "ConfigMap without config.yaml: key written" "ConfigMap:enableUserWorkload: true" "{\"$CM\": {\"data\": {\"other\": \"x\"}}}"
c "empty config.yaml: key written" "ConfigMap:enableUserWorkload: true" "{\"$CM\": {\"data\": {\"config.yaml\": \"\"}}}"
c "malformed content: render refused, nothing written" "FAIL: cluster-monitoring-config config.yaml does not parse: error converting YAML to JSON: yaml: did not find expected key" "{\"$CM\": {\"data\": {\"config.yaml\": \": not: yaml: [\\n\"}}}"
# helm's fromYaml reports non-mapping documents as parse errors; ACM's fromYAML parses them and the mapping check refuses them
c "a list instead of a mapping: refused" "FAIL: cluster-monitoring-config config.yaml does not parse: error unmarshaling JSON: while decoding JSON: json: cannot unmarshal array into Go value of type map[string]interface {}" "{\"$CM\": {\"data\": {\"config.yaml\": \"- a\\n- b\\n\"}}}"
c "a bare false: refused, not defaulted" "FAIL: cluster-monitoring-config config.yaml does not parse: error unmarshaling JSON: while decoding JSON: json: cannot unmarshal bool into Go value of type map[string]interface {}" "{\"$CM\": {\"data\": {\"config.yaml\": \"false\\n\"}}}"
c "a bare number: refused, not defaulted" "FAIL: cluster-monitoring-config config.yaml does not parse: error unmarshaling JSON: while decoding JSON: json: cannot unmarshal number into Go value of type map[string]interface {}" "{\"$CM\": {\"data\": {\"config.yaml\": \"0\\n\"}}}"
c "whitespace only: treated as empty, key written" "ConfigMap:enableUserWorkload: true" "{\"$CM\": {\"data\": {\"config.yaml\": \"  \\n\"}}}"
SUBS='operators.coreos.com/v1alpha1|Subscription||'; OG='operators.coreos.com/v1|OperatorGroup|openshift-cluster-observability-operator|'
t "no operator anywhere: namespace, group, subscription" "Namespace:/openshift-cluster-observability-operator OperatorGroup:openshift-cluster-observability-operator/openshift-cluster-observability-operator Subscription:openshift-cluster-observability-operator/cluster-observability-operator " "$T/coo.tpl" "{\"$SUBS\": {\"items\": []}, \"$OG\": {\"items\": []}}"
t "operator installed elsewhere: adopted, nothing rendered" "" "$T/coo.tpl" "{\"$SUBS\": {\"items\": [{\"spec\": {\"name\": \"cluster-observability-operator\"}, \"metadata\": {\"namespace\": \"other\"}}]}, \"$OG\": {\"items\": []}}"
t "other subscriptions only: installed" "Namespace:/openshift-cluster-observability-operator OperatorGroup:openshift-cluster-observability-operator/openshift-cluster-observability-operator Subscription:openshift-cluster-observability-operator/cluster-observability-operator " "$T/coo.tpl" "{\"$SUBS\": {\"items\": [{\"spec\": {\"name\": \"loki-operator\"}}]}, \"$OG\": {\"items\": []}}"
t "namespace has one all-namespaces OperatorGroup: reused" "Namespace:/openshift-cluster-observability-operator Subscription:openshift-cluster-observability-operator/cluster-observability-operator " "$T/coo.tpl" "{\"$SUBS\": {\"items\": []}, \"$OG\": {\"items\": [{\"metadata\": {\"name\": \"existing\"}, \"spec\": {}}]}}"
t "namespace has a targeted OperatorGroup: refused" "FAIL: OperatorGroup openshift-cluster-observability-operator/scoped targets namespaces; the operator needs an all-namespaces group" "$T/coo.tpl" "{\"$SUBS\": {\"items\": []}, \"$OG\": {\"items\": [{\"metadata\": {\"name\": \"scoped\"}, \"spec\": {\"targetNamespaces\": [\"x\"]}}]}}"
t "namespace has two OperatorGroups: refused" "FAIL: namespace openshift-cluster-observability-operator has 2 OperatorGroups; the operator needs exactly one" "$T/coo.tpl" "{\"$SUBS\": {\"items\": []}, \"$OG\": {\"items\": [{\"metadata\": {\"name\": \"a\"}, \"spec\": {}}, {\"metadata\": {\"name\": \"b\"}, \"spec\": {}}]}}"
ADDON='addon.open-cluster-management.io/v1alpha1|ClusterManagementAddOn||multicluster-observability-addon'
t "registration uses the addon's own placement" "Addon:site-set/open-cluster-management-observability:ai-grid-platform-metrics,ai-grid-user-workload-metrics " "$T/reg.tpl" "{\"$ADDON\": {\"spec\": {\"installStrategy\": {\"placements\": [{\"name\": \"site-set\", \"namespace\": \"open-cluster-management-observability\", \"configs\": []}]}}}}"
t "addon absent: waits" "FAIL: waiting for the multicluster-observability-addon ClusterManagementAddOn" "$T/reg.tpl" '{}'
t "two placements: refuses to guess" "FAIL: the addon has 2 placements; exactly one is expected" "$T/reg.tpl" "{\"$ADDON\": {\"spec\": {\"installStrategy\": {\"placements\": [{\"name\": \"a\", \"namespace\": \"x\"}, {\"name\": \"b\", \"namespace\": \"y\"}]}}}}"
t "addon without placements: refuses" "FAIL: the addon has 0 placements; exactly one is expected" "$T/reg.tpl" "{\"$ADDON\": {\"spec\": {\"installStrategy\": {}}}}"
echo "monitoring-policy tests: $((total-fails)) ok, $fails failed"; exit "$fails"
