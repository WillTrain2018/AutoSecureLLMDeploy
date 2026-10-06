"""
TechCorp LLM Inference API
==========================
This is the sample FastAPI application for the Module 1 hands-on practice.
Your task is to containerize this application using Docker and deploy it
using an automated CI/CD pipeline.

Current Issues (to be fixed during the exercise):
- No health check endpoint
- No model versioning
- No graceful shutdown handling
"""

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional
import time
import os

app = FastAPI(
    title="TechCorp LLM API",
    description="Customer Service and Fraud Detection LLM Endpoint",
    version="1.0.0"
)

# Model configuration (in production, these would be loaded from environment)
MODEL_NAME = os.getenv("MODEL_NAME", "llama-3.1-8b")
MODEL_VERSION = os.getenv("MODEL_VERSION", "v1.0.0")


class InferenceRequest(BaseModel):
    """Request schema for LLM inference"""
    prompt: str
    max_tokens: Optional[int] = 512
    temperature: Optional[float] = 0.7
    model_type: Optional[str] = "customer_service"  # or "fraud_detection"


class InferenceResponse(BaseModel):
    """Response schema for LLM inference"""
    response: str
    model: str
    model_version: str
    tokens_used: int
    latency_ms: float


class HealthResponse(BaseModel):
    """Health check response"""
    status: str
    model_loaded: bool
    version: str


# Simulated model loading status
model_loaded = True


@app.get("/")
def root():
    """Root endpoint"""
    return {"message": "TechCorp LLM API", "version": "1.0.0"}


@app.get("/health", response_model=HealthResponse)
def health_check():
    """
    Health check endpoint for container orchestration.
    Used by Kubernetes liveness and readiness probes.
    """
    return HealthResponse(
        status="healthy" if model_loaded else "unhealthy",
        model_loaded=model_loaded,
        version=MODEL_VERSION
    )


@app.post("/v1/inference", response_model=InferenceResponse)
def inference(request: InferenceRequest):
    """
    Main inference endpoint for LLM requests.
    
    In production, this would call the actual LLM model (e.g., vLLM server).
    For this exercise, we simulate the response.
    """
    start_time = time.time()
    
    if not model_loaded:
        raise HTTPException(status_code=503, detail="Model not loaded")
    
    if len(request.prompt) > 4096:
        raise HTTPException(status_code=400, detail="Prompt exceeds maximum length")
    
    # Simulate inference delay (replace with actual model call)
    time.sleep(0.1)
    
    # Simulated response
    if request.model_type == "fraud_detection":
        response_text = f"Fraud analysis complete. Risk score: 0.23. Recommendation: APPROVE"
    else:
        response_text = f"Thank you for contacting TechCorp. Based on your inquiry: '{request.prompt[:50]}...', I recommend checking our FAQ section."
    
    latency = (time.time() - start_time) * 1000
    
    return InferenceResponse(
        response=response_text,
        model=MODEL_NAME,
        model_version=MODEL_VERSION,
        tokens_used=len(response_text.split()),
        latency_ms=round(latency, 2)
    )


@app.get("/v1/models")
def list_models():
    """List available models"""
    return {
        "models": [
            {"name": "llama-3.1-8b", "type": "customer_service", "status": "loaded"},
            {"name": "llama-3.1-70b", "type": "fraud_detection", "status": "loaded"}
        ]
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
