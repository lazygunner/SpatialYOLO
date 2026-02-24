#!/usr/bin/env python3
"""
FER (Facial Expression Recognition) → CoreML 转换脚本
=======================================================
模型来源: dima806/facial_emotions_image_detection (Hugging Face)
架构:     ViT-base-patch16-224，85.8M 参数
情绪类别: sad / disgust / angry / neutral / fear / surprise / happy
精度:     90.92%

输出: FacialEmotionDetection.mlpackage（供 visionOS 使用）

依赖安装（Python 3.10+ 推荐）:
    pip install torch torchvision transformers coremltools pillow numpy

运行:
    python convert_fer_to_coreml.py
"""

import os
import sys
import json
import numpy as np
from pathlib import Path

import torch
import torch.nn as nn
import coremltools as ct
from transformers import AutoModelForImageClassification, AutoImageProcessor
from PIL import Image

# ── 配置 ──────────────────────────────────────────────────────────────────────

MODEL_ID    = "dima806/facial_emotions_image_detection"
OUTPUT_PATH = "FacialEmotionDetection.mlpackage"
IMAGE_SIZE  = 224
QUANTIZE    = True   # 是否启用 int8 权重量化（推荐：体积减半，精度损失极小）

# ── 工具：含 Softmax 的包装器 ─────────────────────────────────────────────────

class ModelWithSoftmax(nn.Module):
    """输出 softmax 概率，省去 Swift 端手动 softmax"""
    def __init__(self, base: nn.Module):
        super().__init__()
        self.base = base

    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        return torch.softmax(self.base(pixel_values).logits, dim=-1)

# ── Step 1: 加载模型 ──────────────────────────────────────────────────────────

def load_model(model_id: str):
    print(f"\n[1/5] 加载模型: {model_id}")

    processor = AutoImageProcessor.from_pretrained(model_id)
    base      = AutoModelForImageClassification.from_pretrained(
        model_id, torchscript=True   # 提示模型导出友好
    )
    base.eval()

    model = ModelWithSoftmax(base)
    model.eval()

    n_params = sum(p.numel() for p in base.parameters())
    print(f"     参数量  : {n_params:,}  ({n_params * 4 / 1e6:.1f} MB F32)")
    print(f"     标签映射: {base.config.id2label}")
    print(f"     归一化  : mean={processor.image_mean}  std={processor.image_std}")

    return model, processor, dict(base.config.id2label)

# ── Step 2: 转换为 CoreML ─────────────────────────────────────────────────────

def _try_trace(model: nn.Module, dummy: torch.Tensor) -> torch.jit.ScriptModule:
    print("     尝试 torch.jit.trace ...")
    with torch.no_grad():
        traced = torch.jit.trace(model, dummy, strict=False)
    traced.eval()
    return traced


def _try_export(model: nn.Module, dummy: torch.Tensor):
    print("     尝试 torch.export ...")
    with torch.no_grad():
        exported = torch.export.export(model, (dummy,))
    return exported


def convert(model: nn.Module, processor, id2label: dict):
    print("\n[2/5] 转换为 CoreML ...")

    mean = processor.image_mean   # e.g. [0.5, 0.5, 0.5]
    std  = processor.image_std    # e.g. [0.5, 0.5, 0.5]
    dummy = torch.zeros(1, 3, IMAGE_SIZE, IMAGE_SIZE)

    input_spec  = [ct.TensorType(
        name="pixel_values",
        shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE),
        dtype=np.float32,
    )]
    output_spec = [ct.TensorType(name="probabilities", dtype=np.float32)]
    common_kwargs = dict(
        inputs=input_spec,
        outputs=output_spec,
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
    )

    mlmodel = None

    # 优先 trace（ViT-base 的注意力机制在 trace 模式下通常能正常处理）
    try:
        traced  = _try_trace(model, dummy)
        mlmodel = ct.convert(traced, **common_kwargs)
        print("     ✓ torch.jit.trace 转换成功")
    except Exception as e:
        print(f"     ✗ torch.jit.trace 失败: {e}")

    # 回退到 torch.export
    if mlmodel is None:
        try:
            exported = _try_export(model, dummy)
            mlmodel  = ct.convert(exported, **common_kwargs)
            print("     ✓ torch.export 转换成功")
        except Exception as e:
            print(f"     ✗ torch.export 也失败: {e}")
            sys.exit(1)

    return mlmodel, mean, std

# ── Step 3: 元数据 ────────────────────────────────────────────────────────────

def add_metadata(mlmodel, mean, std, id2label: dict):
    print("\n[3/5] 写入元数据 ...")

    mlmodel.author            = f"Converted from HuggingFace — {MODEL_ID}"
    mlmodel.short_description = "Facial expression recognition (7 emotions, ViT-base)"
    mlmodel.version           = "1.0"

    mlmodel.input_description["pixel_values"] = (
        f"Float32 RGB 图像 {IMAGE_SIZE}×{IMAGE_SIZE}，"
        f"需预先归一化: mean={mean}, std={std}"
    )
    mlmodel.output_description["probabilities"] = (
        "各情绪类别的 softmax 概率，顺序见 user_defined_metadata[id2label]"
    )

    # 将标签顺序写入 metadata，Swift 端按此顺序建立映射
    mlmodel.user_defined_metadata["id2label"]   = json.dumps(id2label)
    mlmodel.user_defined_metadata["image_mean"] = json.dumps(mean)
    mlmodel.user_defined_metadata["image_std"]  = json.dumps(std)
    mlmodel.user_defined_metadata["image_size"] = str(IMAGE_SIZE)

    return mlmodel

# ── Step 4: 量化（可选） ──────────────────────────────────────────────────────

def quantize(mlmodel):
    print("\n[4/5] Int8 权重量化 ...")
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )
    cfg = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(
            mode="linear_symmetric",
            dtype="int8",
            granularity="per_channel",
        )
    )
    quantized = linear_quantize_weights(mlmodel, cfg)
    print("     ✓ 量化完成")
    return quantized

# ── Step 5: 验证 ──────────────────────────────────────────────────────────────

def verify(mlmodel, processor, id2label: dict):
    print("\n[5/5] 验证推理 ...")

    # 构造随机测试图像
    dummy_img = Image.fromarray(
        np.random.randint(0, 255, (IMAGE_SIZE, IMAGE_SIZE, 3), dtype=np.uint8)
    )
    inputs = processor(images=dummy_img, return_tensors="np")
    pixel_values = inputs["pixel_values"].astype(np.float32)

    result = mlmodel.predict({"pixel_values": pixel_values})
    probs  = np.array(result["probabilities"]).flatten()

    top_i = int(np.argmax(probs))
    print(f"     输出 shape : {probs.shape}")
    print(f"     Top 预测   : [{top_i}] {id2label.get(str(top_i), top_i)}  ({probs[top_i]:.3f})")
    print(f"     完整分布   : { {id2label.get(str(i), i): round(float(p), 3) for i, p in enumerate(probs)} }")

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    print("=" * 60)
    print("  FER → CoreML 转换脚本")
    print(f"  模型: {MODEL_ID}")
    print(f"  输出: {OUTPUT_PATH}")
    print("=" * 60)

    model, processor, id2label = load_model(MODEL_ID)
    mlmodel, mean, std          = convert(model, processor, id2label)
    mlmodel                     = add_metadata(mlmodel, mean, std, id2label)

    if QUANTIZE:
        mlmodel = quantize(mlmodel)
    else:
        print("\n[4/5] 跳过量化（QUANTIZE=False）")

    verify(mlmodel, processor, id2label)

    mlmodel.save(OUTPUT_PATH)

    # 统计文件大小
    total_bytes = sum(
        os.path.getsize(os.path.join(dp, f))
        for dp, _, files in os.walk(OUTPUT_PATH)
        for f in files
    )
    print(f"\n{'=' * 60}")
    print(f"  ✓ 保存至: {OUTPUT_PATH}  ({total_bytes / 1e6:.1f} MB)")
    print(f"{'=' * 60}")

    print("\n模型标签顺序（Swift 端按此建立 FaceExpression 映射）:")
    for k, v in sorted(id2label.items(), key=lambda x: int(x[0])):
        print(f"  [{k}] {v}")

    print("""
下一步：
  1. 将 FacialEmotionDetection.mlpackage 拖入 Xcode 项目 Build Resources
  2. 参考 doc/fer_swift_integration.md 修改 FaceDetectionService.swift
""")


if __name__ == "__main__":
    main()
