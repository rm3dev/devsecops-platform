"""Unit tests for orders-api - collected by pytest in the pipeline's unitTests
stage (JUnit XML + coverage are archived automatically; see runUnitTests.groovy).
"""
import importlib
import os

import app


def test_order_summary_contract():
    summary = app.order_summary()
    assert summary["service"] == "orders-api"
    assert summary["count"] == 0
    assert isinstance(summary["orders"], list)
    assert summary["logLevel"] in ("debug", "info", "warning", "error")


def test_default_port_matches_chart_values():
    # chart values.yaml config.HTTP_PORT = "8080"; with no env override the
    # app must default to the same port the Service/probes target
    os.environ.pop("HTTP_PORT", None)
    os.environ.pop("PORT", None)
    fresh = importlib.reload(app)
    assert fresh.HTTP_PORT == 8080
    importlib.reload(app)


def test_handler_implements_get():
    assert callable(app.Handler.do_GET)
