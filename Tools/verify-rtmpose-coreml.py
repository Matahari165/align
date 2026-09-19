"""Compare locally converted Core ML SimCC outputs with the exact ONNX model."""

import argparse
from pathlib import Path

import coremltools as ct
import numpy as np
import onnxruntime as ort
from PIL import Image


def image_tensor(path: Path) -> np.ndarray:
    image = Image.open(path).convert("RGB")
    image.thumbnail((192, 256), Image.Resampling.BILINEAR)
    canvas = Image.new("RGB", (192, 256))
    canvas.paste(image, ((192 - image.width) // 2, (256 - image.height) // 2))
    pixels = np.asarray(canvas, dtype=np.float32)
    pixels = (pixels - [123.675, 116.28, 103.53]) / [58.395, 57.12, 57.375]
    return pixels.transpose(2, 0, 1)[None].astype(np.float32)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("onnx_model", type=Path)
    parser.add_argument("model_directory", type=Path)
    parser.add_argument("--sample-image", type=Path)
    args = parser.parse_args()

    reference = ort.InferenceSession(str(args.onnx_model), providers=["CPUExecutionProvider"])
    names = [output.name for output in reference.get_outputs()]
    assert names == ["simcc_x", "simcc_y"], names
    rng = np.random.default_rng(20260919)
    samples = [np.zeros((1, 3, 256, 192), dtype=np.float32)]
    samples.extend(rng.normal(size=(1, 3, 256, 192)).astype(np.float32) for _ in range(2))
    if args.sample_image:
        samples.append(image_tensor(args.sample_image))

    for variant in ("fp32", "int8"):
        url = args.model_directory / f"rtmpose-m-halpe26-native-{variant}.mlpackage"
        model = ct.models.MLModel(str(url), compute_units=ct.ComputeUnit.CPU_ONLY)
        worst_peak = 0
        worst_score = 0.0
        worst_tensor = 0.0
        for sample_number, sample in enumerate(samples):
            original = dict(zip(names, reference.run(names, {"input": sample})))
            converted = model.predict({"input": sample})
            if args.sample_image and sample_number == len(samples) - 1:
                for index, label in ((5, "left shoulder"), (6, "right shoulder"), (18, "neck")):
                    before = [(int(np.argmax(original[name][0, index])), float(np.max(original[name][0, index]))) for name in names]
                    after = [(int(np.argmax(converted[name][0, index])), float(np.max(converted[name][0, index]))) for name in names]
                    print(f"{variant} {label}: onnx={before}, coreml={after}")
                    if variant == "int8":
                        assert all(abs(a[0] - b[0]) <= 2 and abs(a[1] - b[1]) <= 0.05
                                   for a, b in zip(before, after)), f"INT8 changed {label}"
            for name in names:
                a = original[name]
                b = converted[name]
                assert a.shape == b.shape
                assert np.isfinite(b).all()
                worst_tensor = max(worst_tensor, float(np.max(np.abs(a - b))))
                worst_peak = max(worst_peak, int(np.max(np.abs(np.argmax(a, axis=-1) - np.argmax(b, axis=-1)))))
                worst_score = max(worst_score, float(np.max(np.abs(np.max(a, axis=-1) - np.max(b, axis=-1)))))
        print(f"{variant}: peak_bin_max={worst_peak}, score_max_delta={worst_score:.5f}, tensor_max_delta={worst_tensor:.5f}")
        if variant == "fp32":
            assert worst_peak <= 2 and worst_score <= 0.05, "Native FP32 changed keypoint geometry"


if __name__ == "__main__":
    main()
