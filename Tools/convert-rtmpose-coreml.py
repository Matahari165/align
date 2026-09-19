"""Convert the existing local RTMPose ONNX graph to native Core ML variants.

Run in a disposable Python 3.11 environment with coremltools 8.3.0,
onnx2torch 1.5.15, onnx 1.23.0 and torch 2.14.0. Torch 2.14.0 is newer than
coremltools' tested range, so validate every generated artifact numerically.
The private weights remain local and are never committed.
"""

import argparse
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import torch
from onnx2torch import convert


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output_directory", type=Path)
    args = parser.parse_args()

    graph = onnx.load(str(args.source))
    onnx.checker.check_model(graph)
    # ONNX permits an omitted trailing Clip maximum as an empty input name.
    # onnx2torch 1.5.15 instead interprets it as a dynamic, missing tensor.
    for node in graph.graph.node:
        if node.op_type == "Clip" and node.input[-1] == "":
            node.input.pop()
    model = convert(graph).eval()
    sample = torch.zeros((1, 3, 256, 192), dtype=torch.float32)
    with torch.no_grad():
        traced = torch.jit.trace(model, sample, strict=False)
        expected = model(sample)
        actual = traced(sample)
        for original, replay in zip(expected, actual):
            torch.testing.assert_close(original, replay, rtol=1e-4, atol=1e-5)

    args.output_directory.mkdir(parents=True, exist_ok=True)
    result = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT32,
        inputs=[ct.TensorType(name="input", shape=sample.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="simcc_x", dtype=np.float32),
                 ct.TensorType(name="simcc_y", dtype=np.float32)],
    )
    full_path = args.output_directory / "rtmpose-m-halpe26-native-fp32.mlpackage"
    result.save(str(full_path))
    print(f"{full_path}: {result.get_spec().description}", flush=True)

    # FP16 arithmetic moved some SimCC peaks substantially in validation.
    # Compress weights to INT8 instead, retaining FP32 inference arithmetic.
    config = ct.optimize.coreml.OptimizationConfig(
        global_config=ct.optimize.coreml.OpLinearQuantizerConfig(
            mode="linear", dtype="int8", granularity="per_block", block_size=16
        )
    )
    compressed = ct.optimize.coreml.linear_quantize_weights(result, config)
    compressed_path = args.output_directory / "rtmpose-m-halpe26-native-int8.mlpackage"
    compressed.save(str(compressed_path))
    print(f"{compressed_path}: {compressed.get_spec().description}", flush=True)


if __name__ == "__main__":
    main()
