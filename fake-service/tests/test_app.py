"""
Basic tests for fake-service endpoints.
"""
import sys
import os
import pytest
from unittest.mock import patch, MagicMock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


def make_mock_span():
    span = MagicMock()
    ctx = MagicMock()
    ctx.trace_id = 12345678901234567890123456789012
    span.get_span_context.return_value = ctx
    span.__enter__ = lambda s, *a: span
    span.__exit__ = MagicMock(return_value=False)
    return span


@pytest.fixture
def client():
    mock_span = make_mock_span()
    mock_tracer = MagicMock()
    mock_tracer.start_as_current_span.return_value = mock_span

    with patch('opentelemetry.sdk.trace.TracerProvider'), \
         patch('opentelemetry.sdk.metrics.MeterProvider'), \
         patch('opentelemetry.sdk._logs.LoggerProvider'), \
         patch('opentelemetry.exporter.otlp.proto.grpc.trace_exporter.OTLPSpanExporter'), \
         patch('opentelemetry.exporter.otlp.proto.grpc.metric_exporter.OTLPMetricExporter'), \
         patch('opentelemetry.exporter.otlp.proto.grpc._log_exporter.OTLPLogExporter'), \
         patch('threading.Thread'), \
         patch('opentelemetry.trace.get_tracer', return_value=mock_tracer):

        import app as app_module
        app_module.tracer = mock_tracer
        app_module.app.config['TESTING'] = True
        with app_module.app.test_client() as c:
            yield c


def test_health_returns_200(client):
    response = client.get('/health')
    assert response.status_code == 200


def test_health_returns_ok_status(client):
    response = client.get('/health')
    data = response.get_json()
    assert data['status'] == 'ok'


def test_metrics_endpoint_returns_200(client):
    response = client.get('/metrics')
    assert response.status_code == 200


def test_simulate_endpoint_returns_200(client):
    response = client.post('/simulate',
                           json={'endpoint': '/api/users'},
                           content_type='application/json')
    assert response.status_code == 200


def test_simulate_returns_simulated_true(client):
    response = client.post('/simulate',
                           json={'endpoint': '/api/orders'},
                           content_type='application/json')
    data = response.get_json()
    assert data['simulated'] is True


def test_simulate_force_error_returns_500_status(client):
    response = client.post('/simulate',
                           json={'force_error': True},
                           content_type='application/json')
    data = response.get_json()
    assert data['status'] == 500
