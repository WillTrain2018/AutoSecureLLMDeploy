"""
TechCorp LLM Inference API
==========================
FastAPI application for the Module 1 hands-on practice. Containerize this
application using Docker and deploy it using an automated CI/CD pipeline.

Original exercise starter listed three issues; all three are addressed here:

- No health check endpoint
    -> /health is kept (backward compatible with the ALB target group in
       M1_main.tf and the Docker HEALTHCHECK), plus /health/live and
       /health/ready are added so Kubernetes-style liveness and readiness
       probes can be wired separately instead of sharing one meaning.
- No model versioning
    -> MODEL_REGISTRY tracks a version per model; /v1/models reports it.
- No graceful shutdown handling
    -> a lifespan hook flips readiness to "not ready" on shutdown, and
       uvicorn is started with --timeout-graceful-shutdown so in-flight
       requests get time to finish instead of being killed outright. Full
       zero-downtime draining in Kubernetes additionally needs a `preStop`
       hook (e.g. `sleep 5`) in the pod spec, outside this app's control.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from contextlib import asynccontextmanager
from enum import Enum
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from pythonjsonlogger import jsonlogger

# -----------------------------------------------------------------------------
# Structured logging. python-json-logger was already a pinned dependency
# (M1_requirements.txt) but unused - wire it up instead of leaving it dead.
# -----------------------------------------------------------------------------
logger = logging.getLogger("techcorp.llm_api")
if not logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    logger.addHandler(_handler)
    logger.setLevel(logging.INFO)

# -----------------------------------------------------------------------------
# Configuration (in production, these would be loaded from environment)
# -----------------------------------------------------------------------------
MODEL_NAME = os.getenv("MODEL_NAME", "llama-3.1-8b")
MODEL_VERSION = os.getenv("MODEL_VERSION", "v1.0.0")
MAX_PROMPT_LENGTH = int(os.getenv("MAX_PROMPT_LENGTH", "4096"))

# Model registry: name -> (type, version). Previously /v1/models returned a
# hardcoded list with no version field at all.
MODEL_REGISTRY = {
    "llama-3.1-8b": {"type": "customer_service", "version": MODEL_VERSION},
    "llama-3.1-70b": {"type": "fraud_detection", "version": MODEL_VERSION},
}


class ModelType(str, Enum):
    """Supported inference model types. Using an enum instead of a bare
    string prevents a typo (e.g. "coustomer_service") from silently falling
    through to the default branch in inference()."""

    CUSTOMER_SERVICE = "customer_service"
    FRAUD_DETECTION = "fraud_detection"


@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Startup/shutdown lifecycle. Replaces the old module-level
    `model_loaded = True` constant - which never changed for the life of
    the process - with real state on app.state that reflects what's
    actually happening, including during shutdown.
    """
    app.state.start_time = time.monotonic()
    app.state.model_loaded = False
    app.state.shutting_down = False

    logger.info("model_loading", extra={"model": MODEL_NAME, "version": MODEL_VERSION})
    # TODO: replace with the real model/engine load (e.g. a vLLM client init).
    # The weights baked in by download_model.py land at $MODEL_WEIGHTS_DIR
    # (see M1_Dockerfile.template), e.g. /app/models/<name>/<version>/weights.bin.
    app.state.model_loaded = True
    logger.info("model_loaded")

    yield

    # Flip readiness off first so a readiness probe starts failing
    # immediately, then let whatever requests are already in flight finish
    # (bounded by uvicorn's --timeout-graceful-shutdown below).
    app.state.shutting_down = True
    app.state.model_loaded = False
    logger.info("shutting_down")


app = FastAPI(
    title="TechCorp LLM API",
    description="Customer Service and Fraud Detection LLM Endpoint",
    version=MODEL_VERSION,
    lifespan=lifespan,
)


class InferenceRequest(BaseModel):
    """Request schema for LLM inference"""

    model_config = ConfigDict(protected_namespaces=())

    prompt: str = Field(..., min_length=1, max_length=MAX_PROMPT_LENGTH)
    max_tokens: Optional[int] = Field(default=512, ge=1, le=4096)
    temperature: Optional[float] = Field(default=0.7, ge=0.0, le=2.0)
    model_type: ModelType = ModelType.CUSTOMER_SERVICE


class InferenceResponse(BaseModel):
    """Response schema for LLM inference"""

    model_config = ConfigDict(protected_namespaces=())

    response: str
    model: str
    model_version: str
    tokens_used: int
    latency_ms: float


class HealthResponse(BaseModel):
    """Health check response"""

    model_config = ConfigDict(protected_namespaces=())

    status: str
    model_loaded: bool
    version: str
    uptime_s: float


def _health_response() -> HealthResponse:
    healthy = app.state.model_loaded and not app.state.shutting_down
    return HealthResponse(
        status="healthy" if healthy else "unhealthy",
        model_loaded=app.state.model_loaded,
        version=MODEL_VERSION,
        uptime_s=round(time.monotonic() - app.state.start_time, 3),
    )


@app.get("/")
def root():
    """Root endpoint"""
    return {"message": "TechCorp LLM API", "version": app.version}


@app.get("/health", response_model=HealthResponse)
def health():
    """
    Composite health check, kept for backward compatibility with the ALB
    target group health check (M1_main.tf) and the Docker HEALTHCHECK,
    both of which hit this exact path. Equivalent to /health/ready.
    """
    return _health_response()


@app.get("/health/live", response_model=HealthResponse)
def health_live():
    """
    Liveness probe: is the process itself responsive? Deliberately does NOT
    depend on model_loaded - a slow or failed model load should fail
    readiness (pull the pod out of rotation), not liveness (which would get
    the container killed and restarted, never giving it a chance to load).
    """
    return HealthResponse(
        status="alive",
        model_loaded=app.state.model_loaded,
        version=MODEL_VERSION,
        uptime_s=round(time.monotonic() - app.state.start_time, 3),
    )


@app.get("/health/ready", response_model=HealthResponse)
def health_ready():
    """
    Readiness probe: can this instance actually serve traffic right now?
    False while the model is loading, and immediately during shutdown, so
    Kubernetes stops routing new requests while existing ones drain.
    """
    response = _health_response()
    if not (app.state.model_loaded and not app.state.shutting_down):
        raise HTTPException(status_code=503, detail=response.model_dump())
    return response


@app.post("/v1/inference", response_model=InferenceResponse)
async def inference(request: InferenceRequest):
    """
    Main inference endpoint for LLM requests.

    In production, this would call the actual LLM model (e.g., vLLM server).
    For this exercise, we simulate the response.
    """
    start_time = time.perf_counter()

    if not app.state.model_loaded or app.state.shutting_down:
        raise HTTPException(status_code=503, detail="Model not loaded")

    # Simulate inference latency without blocking an event loop/worker
    # thread the way time.sleep() would.
    await asyncio.sleep(0.1)

    if request.model_type is ModelType.FRAUD_DETECTION:
        response_text = "Fraud analysis complete. Risk score: 0.23. Recommendation: APPROVE"
    else:
        response_text = (
            f"Thank you for contacting TechCorp. Based on your inquiry: "
            f"'{request.prompt[:50]}...', I recommend checking our FAQ section."
        )

    latency_ms = (time.perf_counter() - start_time) * 1000
    tokens_used = len(response_text.split())

    logger.info(
        "inference_served",
        extra={
            "model_type": request.model_type.value,
            "tokens_used": tokens_used,
            "latency_ms": round(latency_ms, 2),
        },
    )

    return InferenceResponse(
        response=response_text,
        model=MODEL_NAME,
        model_version=MODEL_VERSION,
        tokens_used=tokens_used,
        latency_ms=round(latency_ms, 2),
    )


@app.get("/v1/models")
def list_models():
    """List available models, each with its own version."""
    return {
        "models": [
            {"name": name, "type": meta["type"], "version": meta["version"], "status": "loaded"}
            for name, meta in MODEL_REGISTRY.items()
        ]
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8000")),
        # Give in-flight requests time to finish on SIGTERM instead of
        # killing them outright - this is the "graceful shutdown handling"
        # called out as missing above.
        timeout_graceful_shutdown=30,
    )
