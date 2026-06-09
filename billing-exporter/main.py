import logging
import os

from google.cloud import bigquery
from opentelemetry import metrics
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "bens-project-462804")

QUERY = f"""
SELECT
  service.description AS service,
  SUM(cost) AS gross_cost,
  SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS credits,
  currency
FROM `{PROJECT_ID}.billing_export.gcp_billing_export_v1_*`
WHERE DATE(_PARTITIONTIME) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
GROUP BY service, currency
ORDER BY gross_cost DESC
"""


def setup_telemetry(service_name: str) -> MeterProvider | None:
    endpoint = os.environ.get("GRAFANA_OTLP_ENDPOINT")
    if not endpoint:
        logger.warning("GRAFANA_OTLP_ENDPOINT not set — metrics will not be exported")
        return None

    token = os.environ.get("GRAFANA_OTLP_TOKEN", "")
    headers = {"Authorization": f"Basic {token}"}
    resource = Resource({"service.name": service_name})

    reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=f"{endpoint}/v1/metrics", headers=headers),
        export_interval_millis=60_000,
    )
    provider = MeterProvider(resource=resource, metric_readers=[reader])
    metrics.set_meter_provider(provider)
    return provider


def main() -> None:
    provider = setup_telemetry("gcp-billing-exporter")
    meter = metrics.get_meter("gcp-billing-exporter")

    monthly_cost = meter.create_gauge(
        "gcp.billing.monthly_cost",
        unit="USD",
        description="Rolling 30-day gross cost by GCP service",
    )
    monthly_credits = meter.create_gauge(
        "gcp.billing.monthly_credits",
        unit="USD",
        description="Rolling 30-day credits (discounts, free tier) by GCP service",
    )

    logger.info("Querying BigQuery billing export for project %s", PROJECT_ID)
    client = bigquery.Client(project=PROJECT_ID)
    rows = list(client.query(QUERY).result())
    logger.info("Got %d rows", len(rows))

    for row in rows:
        attrs = {"service": row.service, "currency": row.currency}
        monthly_cost.set(round(row.gross_cost, 4), attrs)
        monthly_credits.set(round(row.credits, 4), attrs)
        logger.info("  %-45s  cost=%.4f  credits=%.4f  %s",
                    row.service, row.gross_cost, row.credits, row.currency)

    if provider is not None:
        provider.force_flush(timeout_millis=10_000)
        provider.shutdown()
        logger.info("Metrics flushed to Grafana Cloud")


if __name__ == "__main__":
    main()
