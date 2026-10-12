#!/usr/bin/env python3
"""Evaluate the shipped alert expressions with promtool (requires PyYAML)."""
import json
from pathlib import Path
import subprocess
import tempfile

import yaml


ROOT = Path(__file__).resolve().parent.parent


def conversation_cases(rules):
    cases = []

    def series(metric, labels, values):
        return {"series": metric + '{namespace="fountain",' + labels + '}', "values": values}

    def case(name, alert, inputs, labels=None):
        cases.append({
            "name": name, "interval": "1m", "input_series": inputs,
            "promql_expr_test": [{
                "expr": "(" + rules[alert]["expr"].strip() + ") > bool 0",
                "eval_time": "60m",
                "exp_samples": [] if labels is None else [{"labels": labels, "value": 1}],
            }],
        })

    names = ("FountainStageFailures", "FountainTurnFailureRate",
             "FountainReattachFailures", "FountainTurnFirstOutputSlow",
             "FountainBrokerCAInstallFailureRate")
    for alert in names:
        case(alert + ": no series", alert, [])

    for stage in ("clone", "packages", "network_policy", "provision"):
        case("failed stage " + stage, "FountainStageFailures", [
            series("fountain_stage_count", f'stage="{stage}",status="failed"', "0+1x120")
        ], None if stage == "provision" else f'{{stage="{stage}"}}')
    case("healthy stages", "FountainStageFailures", [
        series("fountain_stage_count", 'stage="clone",status="done"', "0+1x120")])
    for fails in (False, True):
        case("reattach fails=" + str(fails), "FountainReattachFailures", [
            series("fountain_stage_count", 'stage="reattach",status="failed"',
                   "0+0x30 1+0x89" if fails else "0+0x120")], "{}" if fails else None)

    for name, failed, done, unavailable, fires in (
        ("healthy, no failure series", None, "0+1x120", None, False),
        ("idle", "0+0x120", "0+0x120", None, False),
        ("too little traffic", "0+0.02x120", None, None, False),
        ("exactly 10 percent", "0+1x120", "0+9x120", None, False),
        ("18 percent fail", "0+0.18x120", "0+0.82x120", None, True),
        ("all fail, no success series", "0+1x120", None, None, True),
        ("transport failure is not an installer exit", None, None, "0+1x120", False),
        ("counter reset", "0+0.18x29 0+0.18x90", "0+0.82x29 0+0.82x90", None, True),
    ):
        inputs = [series("fountain_broker_ca_install_count",
                         f'provider="sprites",outcome="{outcome}"', values)
                  for outcome, values in (("exit", failed), ("ok", done),
                                          ("unreachable", unavailable)) if values is not None]
        # A busy healthy provider and proxy/health request traffic cannot
        # dilute the failing provider's conversation setup ratio.
        inputs.append(series("fountain_broker_ca_install_count",
                             'provider="e2b",outcome="ok"', "0+1000x120"))
        inputs.append(series("fountain_broker_request_count",
                             'outcome="passthrough"', "0+1000x120"))
        case("broker CA: " + name, "FountainBrokerCAInstallFailureRate", inputs,
             '{provider="sprites"}' if fires else None)

    count = "fountain_turn_completed_duration_ms_count"
    for name, failed, done, fires in (
        ("healthy, no failure series", None, "0+1x120", False),
        ("idle", "0+0x120", "0+0x120", False),
        ("too little traffic", "0+0.1x120", "0+0x120", False),
        ("exactly 25 percent", "0+1x120", "0+3x120", False),
        ("half fail", "0+1x120", "0+1x120", True),
        ("all fail, no success series", "0+1x120", None, True),
        ("counter reset", "0+1x39 0+1x80", "0+1x39 0+1x80", True),
    ):
        inputs = [series(count, 'provider="sprites",status="' + status + '"', values)
                  for status, values in (("failed", failed), ("completed", done)) if values is not None]
        # A healthy, much busier provider must not dilute the failing one.
        inputs.append(series(count, 'provider="e2b",status="completed"', "0+100x120"))
        case("turns: " + name, "FountainTurnFailureRate", inputs,
             '{provider="sprites"}' if fires else None)

    for name, slow, traffic in (("slow", True, 1), ("fast", False, 1), ("low traffic", True, 0.1)):
        inputs = [series("fountain_turn_first_output_elapsed_ms_bucket",
                         f'provider="sprites",le="{le}"', f"0+{step}x120")
                  for le, step in (("30000", 0 if slow else traffic), ("60000", traffic), ("+Inf", traffic))]
        inputs.append(series("fountain_turn_first_output_elapsed_ms_count", 'provider="sprites"', f"0+{traffic}x120"))
        case("first output: " + name, "FountainTurnFirstOutputSlow", inputs,
             '{provider="sprites"}' if slow and traffic == 1 else None)
        if name == "slow":
            rule = rules["FountainTurnFirstOutputSlow"]
            cases[-1]["alert_rule_test"] = [
                {"eval_time": "14m", "alertname": "FountainTurnFirstOutputSlow", "exp_alerts": []},
                {"eval_time": "60m", "alertname": "FountainTurnFirstOutputSlow", "exp_alerts": [{
                    "exp_labels": {"provider": "sprites", "severity": "warning"},
                    "exp_annotations": {key: value.replace("{{ $labels.provider }}", "sprites")
                                        for key, value in rule["annotations"].items()},
                }]},
            ]
    return cases


def email_dashboard_cases():
    dashboard = json.loads((ROOT / "deploy/grafana/fountain-ops.json").read_text())
    expression = next(target["expr"] for panel in dashboard["panels"]
                      for target in panel.get("targets", [])
                      if "fountain_email_delivery_exception" in target.get("expr", ""))
    expression = expression.replace("$namespace", "fountain")
    cases = []
    for errors, exceptions in ((False, False), (True, False), (False, True), (True, True)):
        inputs = []
        for present, metric in (
            (errors, 'fountain_email_delivery_count{namespace="fountain",outcome="error"}'),
            (exceptions, 'fountain_email_delivery_exception{namespace="fountain"}'),
        ):
            if present:
                inputs.append({"series": metric, "values": "0+0x30 1+0x90"})
        cases.append({
            "name": f"email dashboard: errors={errors}, exceptions={exceptions}",
            "interval": "1m", "input_series": inputs,
            "promql_expr_test": [{
                "expr": expression, "eval_time": "60m",
                "exp_samples": [{"labels": "{}", "value": int(errors) + int(exceptions)}],
            }],
        })
    return cases


def main():
    spec = yaml.safe_load((ROOT / "deploy/k8s/prometheusrule.yaml").read_text())["spec"]
    rules = {r["alert"]: r for g in spec["groups"] for r in g["rules"]}
    cases = conversation_cases(rules) + email_dashboard_cases()
    for replicas in (1, 2, 3):
        for alert, metric, statuses in (
            ("FountainSandboxBudgetExceeded", "fountain_sandboxes_count", ("pending", "ready")),
            ("FountainConversationsAboveBudget", "fountain_conversations_count", ("pending", "running")),
        ):
            for counts in ((10, 20), (20, 40)):
                series = [
                    {"series": f'{metric}{{namespace="fountain",status="{status}",pod="pod-{pod}"}}',
                     "values": f"{count}+0x120"}
                    for pod in range(replicas)
                    for status, count in zip(statuses, counts)
                ]
                total = sum(counts)
                cases.append({
                    "name": f"{alert}: {replicas} replicas, {total} rows",
                    "interval": "1m", "input_series": series,
                    "promql_expr_test": [{"expr": rules[alert]["expr"], "eval_time": "120m",
                                          "exp_samples": [{"labels": "{}", "value": total}] if total > 50 else []}],
                })

        for alert, state in (("FountainObanQueueBacklog", "available"),
                             ("FountainObanJobsDiscarded", "discarded")):
            for fires in (False, True):
                values = ("30+0x120" if fires else "20+0x120") if state == "available" else (
                    "0+0x59 1+0x60" if fires else "1+0x120")
                # Assert alert membership rather than delta's fractional
                # extrapolation, which differs between Prometheus 2 and 3.
                expression = rules[alert]["expr"]
                if state == "discarded":
                    expression = f"({expression.strip()}) > bool 0"
                value = 30 if state == "available" else 1
                series = [
                    {"series": f'fountain_oban_queue_depth{{namespace="fountain",queue="default",state="{state}",pod="pod-{pod}"}}',
                     "values": values}
                    for pod in range(replicas)
                ]
                # A second quiet queue must neither add to the first nor page.
                series.append({"series": f'fountain_oban_queue_depth{{namespace="fountain",queue="quiet",state="{state}",pod="pod-0"}}',
                               "values": "0+0x120"})
                cases.append({
                    "name": f"{alert}: {replicas} replicas, fires={fires}",
                    "interval": "1m", "input_series": series,
                    "promql_expr_test": [{"expr": expression, "eval_time": "120m",
                                          "exp_samples": [{"labels": f'{{namespace="fountain",queue="default",state="{state}"}}',
                                                           "value": value}] if fires else []}],
                })

    with tempfile.TemporaryDirectory(prefix="fountain-alert-tests-") as directory:
        rule_file = Path(directory) / "rules.yml"
        rule_file.write_text(yaml.safe_dump(spec))
        test_file = Path(directory) / "tests.yml"
        test_file.write_text(yaml.safe_dump({"rule_files": [str(rule_file)], "evaluation_interval": "1m", "tests": cases}))
        subprocess.run(["promtool", "check", "rules", str(rule_file)], check=True)
        subprocess.run(["promtool", "test", "rules", str(test_file)], check=True)
    print(f"Passed {len(cases)} alert expression cases")


if __name__ == "__main__":
    main()
