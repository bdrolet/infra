/**
 * OpenTelemetry SDK initializer for Node.js / TypeScript.
 *
 * Import this module FIRST, before any other imports, at your app entry point:
 *   import './telemetry';
 *   import express from 'express';
 *   ...
 *
 * Required env vars (set via Kubernetes downward API + your app config):
 *   HOST_IP              — injected by the DaemonSet pod spec; routes to the node-local collector
 *   OTEL_SERVICE_NAME    — e.g. "my-api"
 *
 * Optional env vars (OTel SDK reads these automatically):
 *   OTEL_SERVICE_VERSION — defaults to package.json version
 *   OTEL_RESOURCE_ATTRIBUTES — comma-separated key=value pairs for extra resource attributes
 */

import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-proto';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-proto';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-proto';
import { PeriodicExportingMetricReader } from '@opentelemetry/sdk-metrics';
import { BatchLogRecordProcessor } from '@opentelemetry/sdk-logs';
import { Resource } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from '@opentelemetry/semantic-conventions';

const hostIp = process.env.HOST_IP ?? 'localhost';
const collectorBase = `http://${hostIp}:4318`;

const sdk = new NodeSDK({
  resource: new Resource({
    [ATTR_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME ?? 'unknown-service',
    [ATTR_SERVICE_VERSION]: process.env.npm_package_version ?? '0.0.0',
  }),

  traceExporter: new OTLPTraceExporter({
    url: `${collectorBase}/v1/traces`,
  }),

  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter({
      url: `${collectorBase}/v1/metrics`,
    }),
    exportIntervalMillis: 30_000,
  }),

  logRecordProcessor: new BatchLogRecordProcessor(
    new OTLPLogExporter({
      url: `${collectorBase}/v1/logs`,
    }),
  ),

  instrumentations: [
    getNodeAutoInstrumentations({
      // Reduces noise from internal health-check polling
      '@opentelemetry/instrumentation-fs': { enabled: false },
    }),
  ],
});

sdk.start();

process.on('SIGTERM', () => {
  sdk.shutdown().finally(() => process.exit(0));
});
