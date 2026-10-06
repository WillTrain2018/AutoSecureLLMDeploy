#!/usr/bin/env python3
"""
Download the model weights needed at runtime - run as its own cached Docker
build layer (see M1_Dockerfile.template), separate from both the Python
dependency install and the application code layers, so a code edit or a
dependency bump never forces a redundant multi-GB re-download.

This intentionally supports two paths so the Docker build stays runnable
today, before AWS credentials are configured in CI (see the "Configure
proper secrets" TODO in M1_github_workflow.yml) and before a real weights
object exists in the model bucket:

  - Real path: if boto3 can resolve credentials AND the object exists in
    MODEL_BUCKET, it's downloaded from S3 - matching the s3:GetObject IAM
    permission already granted to the instance role in M1_main.tf.
  - Placeholder path: otherwise, a small stub file is written instead, so
    the layer-caching behavior (the actual point of this exercise) can be
    built and tested without live cloud access. A loud warning is printed
    so nobody mistakes the stub for a real deployment.

Usage:
    python3 download_model.py --dest /build/model-weights
"""

from __future__ import annotations

import argparse
import os
import sys


def download_from_s3(bucket: str, key: str, dest_path: str) -> bool:
    """
    Try a real S3 download. Never raises - returns False on any failure
    (boto3 missing, no credentials, bucket/key not found, etc.) so the
    caller can fall back to the placeholder path instead of hard-failing
    the whole image build.
    """
    try:
        import boto3
        from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError
    except ImportError:
        print(f"[download_model] boto3 not available, skipping S3 fetch for s3://{bucket}/{key}")
        return False

    try:
        s3 = boto3.client("s3")
        s3.download_file(bucket, key, dest_path)
        print(f"[download_model] downloaded s3://{bucket}/{key} -> {dest_path}")
        return True
    except (BotoCoreError, ClientError, NoCredentialsError) as exc:
        print(f"[download_model] could not fetch s3://{bucket}/{key} ({exc}); falling back to placeholder")
        return False


def write_placeholder(dest_path: str, model_name: str, model_version: str) -> None:
    with open(dest_path, "w") as f:
        f.write(
            f"PLACEHOLDER WEIGHTS - model={model_name} version={model_version}\n"
            "No real weights were downloaded. Replace this by configuring AWS\n"
            "credentials in CI and publishing real weights to the model bucket\n"
            "before deploying this image to production.\n"
        )
    print(f"[download_model] WARNING: wrote placeholder weights to {dest_path} (no real weights were downloaded)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bucket", default=os.getenv("MODEL_BUCKET", "techcorp-llm-models"))
    parser.add_argument("--model", default=os.getenv("MODEL_NAME", "llama-3.1-8b"))
    parser.add_argument("--version", default=os.getenv("MODEL_VERSION", "v1.0.0"))
    parser.add_argument("--dest", default=os.getenv("MODEL_WEIGHTS_DIR", "/build/model-weights"))
    args = parser.parse_args()

    key = f"{args.model}/{args.version}/weights.bin"
    dest_dir = os.path.join(args.dest, args.model, args.version)
    dest_path = os.path.join(dest_dir, "weights.bin")
    os.makedirs(dest_dir, exist_ok=True)

    if not download_from_s3(args.bucket, key, dest_path):
        write_placeholder(dest_path, args.model, args.version)

    return 0


if __name__ == "__main__":
    sys.exit(main())
