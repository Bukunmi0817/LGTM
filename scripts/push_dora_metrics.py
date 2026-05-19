#!/usr/bin/env python3
"""
Push DORA metrics directly to Pushgateway via HTTP.
Uses MONITOR_SERVER_IP environment variable set from GitHub secret.
"""
import urllib.request
import os
import sys

def push(url, data):
    try:
        req = urllib.request.Request(url, data=data.encode(), method="POST")
        urllib.request.urlopen(req, timeout=10)
        print(f"Pushed to {url}")
        return True
    except Exception as e:
        print(f"Warning: push failed to {url}: {e}")
        return False

monitor  = os.environ.get("MONITOR_SERVER_IP", "")
run_id   = os.environ.get("RUN_ID", "")
branch   = os.environ.get("BRANCH", "main")
repo     = os.environ.get("REPO", "")
workflow = os.environ.get("WORKFLOW", "")
commit   = os.environ.get("COMMIT_SHA", "")
status   = os.environ.get("JOB_STATUS", "failure")

deploy_end               = int(os.environ.get("DEPLOY_END", "0"))
lead_time_total          = int(os.environ.get("LEAD_TIME_TOTAL", "0"))
lead_time_commit_trigger = int(os.environ.get("LEAD_TIME_COMMIT_TO_TRIGGER", "0"))
lead_time_trigger_build  = int(os.environ.get("LEAD_TIME_TRIGGER_TO_BUILD", "0"))
lead_time_build_deploy   = int(os.environ.get("LEAD_TIME_BUILD_TO_DEPLOY", "0"))
status_value             = 0 if status == "success" else 1

if not monitor:
    print("MONITOR_SERVER_IP not set — skipping metrics push")
    sys.exit(0)

run_metrics = (
    "# HELP github_deploy_timestamp_seconds Unix timestamp of this run\n"
    "# TYPE github_deploy_timestamp_seconds gauge\n"
    f'github_deploy_timestamp_seconds{{runid="{run_id}",branch="{branch}",status="{status}",repo="{repo}"}} {deploy_end}\n'
    "# HELP github_deploy_lead_time_seconds Total lead time\n"
    "# TYPE github_deploy_lead_time_seconds gauge\n"
    f'github_deploy_lead_time_seconds{{runid="{run_id}",branch="{branch}"}} {lead_time_total}\n'
    "# HELP github_deploy_commit_to_trigger_seconds Commit to trigger\n"
    "# TYPE github_deploy_commit_to_trigger_seconds gauge\n"
    f'github_deploy_commit_to_trigger_seconds{{runid="{run_id}",branch="{branch}"}} {lead_time_commit_trigger}\n'
    "# HELP github_deploy_trigger_to_build_seconds Trigger to build\n"
    "# TYPE github_deploy_trigger_to_build_seconds gauge\n"
    f'github_deploy_trigger_to_build_seconds{{runid="{run_id}",branch="{branch}"}} {lead_time_trigger_build}\n'
    "# HELP github_deploy_build_to_deploy_seconds Build to deploy\n"
    "# TYPE github_deploy_build_to_deploy_seconds gauge\n"
    f'github_deploy_build_to_deploy_seconds{{runid="{run_id}",branch="{branch}"}} {lead_time_build_deploy}\n'
)

latest_metrics = (
    "# HELP github_last_deploy_status Last deploy 0=success 1=failure\n"
    "# TYPE github_last_deploy_status gauge\n"
    f'github_last_deploy_status{{branch="{branch}",workflow="{workflow}",commit="{commit}"}} {status_value}\n'
    "# HELP github_last_deploy_timestamp_seconds Last deploy timestamp\n"
    "# TYPE github_last_deploy_timestamp_seconds gauge\n"
    f'github_last_deploy_timestamp_seconds{{branch="{branch}"}} {deploy_end}\n'
)

base = f"http://{monitor}:9091/metrics"
push(f"{base}/job/github-deploy/runid/{run_id}", run_metrics)
push(f"{base}/job/github-deploy-latest/branch/{branch}", latest_metrics)

print(f"Done — Status: {status} | Lead time: {lead_time_total}s")
