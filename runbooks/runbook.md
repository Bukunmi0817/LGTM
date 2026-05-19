# Runbooks

Operational runbooks for every alert in the LGTM stack. Each file covers the alerts for one category.

| File | Alerts |
|---|---|
| [cpu.md](cpu.md) | `CPUWarning`, `CPUCritical` |
| [memory.md](memory.md) | `MemoryWarning`, `MemoryCritical` |
| [disk.md](disk.md) | `DiskWarning`, `DiskCritical` |
| [server_availability.md](server_availability.md) | `ServerDown`, `ServerRecovered` |
| [slo_burn_rate.md](slo_burn_rate.md) | `SLOFastBurn`, `SLOSlowBurn`, `LatencySLOFastBurn` |
| [cicd.md](cicd.md) | `DeploymentFailed`, `HighChangeFailureRate`, `MTTRExceeded` |

## Dashboards

| Dashboard | URL |
|---|---|
| Node Exporter | `http://<monitoring-ip>:3000/d/node-exporter/node-exporter` |
| Blackbox Exporter | `http://<monitoring-ip>:3000/d/blackbox/blackbox-exporter` |
| SLO / Error Budget | `http://<monitoring-ip>:3000/d/slo-error-budget/slo-and-error-budget` |
| DORA Metrics | `http://<monitoring-ip>:3000/d/dora-metrics/dora-metrics` |
| Golden Signals | `http://<monitoring-ip>:3000/d/golden-signals/golden-signals` |
