[en](./REAME.md) | [ko](./README(ko).md) | [ja](./README(ja).md)

## Blue-Green Deployment Script for Low-Resource Environments

This script provides a reliable **Blue-Green Deployment** strategy optimized for servers with limited CPU/RAM resources (e.g., Raspberry Pi, small Cloud VMs).

### Key Features:
- **Resource Optimization:** Strategically stops CPU-intensive background workers (Celery) from the old environment before starting the new one to prevent CPU spikes.
- **Health Checks:** Automatically verifies the new environment's status before switching traffic.
- **Graceful Rollback:** If the new environment fails the health check, the script automatically restores the previous environment's background services.
- **Manual Verification:** Includes a "Human-in-the-loop" step, allowing administrators to verify the deployment before permanently destroying the old containers.
- **Project Isolation:** Uses Docker Compose project names (`-p`) to run two identical environments side-by-side.
