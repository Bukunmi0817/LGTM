"""
Basic tests for fake-service endpoints.
"""
import pytest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

@pytest.fixture
def client():
    from unittest.mock import patch, MagicMock

    with patch('opentelemetry.sdk.trace.TracerProvider'), \
         patch('opentelemetry.sdk.metrics.MeterProvider'), \
         patch('opentelemetry.sdk._logs.LoggerProvider'), \
         patch('opentelemetry.exporter.otlp.proto.grpc.trace_exporter.OTLPSpanExporter'), \
         patch('opentelemetry.exporter.otlp.proto.grpc.metric_exporter.OTLPMetricExporter'), \
         patch('opentelemetry.exporter.otlp.proto.grpc._log_exporter.OTLPLogExporter'), \
         patch('threading.Thread'):

        import importlib
        import fake_service.app as app_module
        importlib.reload(app_module)

        app_module.app.config['TESTING'] = True
        with app_module.app.test_client() as client:
            yield client


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
