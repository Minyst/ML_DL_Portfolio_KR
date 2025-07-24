from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from transformers import AutoModelForSemanticSegmentation, AutoImageProcessor
from PIL import Image, ImageDraw, ImageFont
import torch
import torch.nn.functional as F
import numpy as np
import cv2
import io
import os
import uvicorn
import base64

# ===== FastAPI 앱 생성 =====
app = FastAPI(title="Smart Recycling Segmentation API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

@app.get("/")
async def root():
    return {
        "message": "Smart Recycling Segmentation API is running!",
        "version": "2.0",
        "features": ["preprocessed_image_support", "optimized_inference"]
    }

@app.get("/health")
async def health():
    return {"status": "healthy", "gpu_available": torch.cuda.is_available()}

# ===== 모델 로드 =====
MODEL_PATH = os.path.abspath(os.path.dirname(__file__))

try:
    print("🤖 모델 로드 중...")
    model = AutoModelForSemanticSegmentation.from_pretrained(MODEL_PATH, local_files_only=True)
    processor = AutoImageProcessor.from_pretrained(MODEL_PATH, local_files_only=True)
    model.eval()
    print("✅ 모델 로드 완료!")
except Exception as e:
    print(f"❌ 모델 로드 실패: {e}")
    model = None
    processor = None

# ===== 설정 =====
class_names = ["background", "can", "glass", "paper", "plastic", "styrofoam", "vinyl"]
class_colors_bright = [
    (0, 0, 0),        # background - 검은색
    (0, 255, 255),    # can - 밝은 청록색
    (255, 255, 0),    # glass - 밝은 노란색
    (128, 255, 0),    # paper - 연두색
    (255, 0, 0),      # plastic - 밝은 빨간색
    (0, 128, 255),    # styrofoam - 밝은 파란색
    (255, 0, 128)     # vinyl - 밝은 분홍색
]

device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
print(f"🔧 디바이스: {device}")

font_path = os.path.join(os.path.dirname(__file__), "Pretendard-SemiBold.otf")

# ===== 후처리 함수들 =====

def remove_tiny_noise_with_confidence(pred_mask: np.ndarray,
                                      single_probs: np.ndarray,
                                      min_area_ratio: float = 0.002,  # 더 관대하게
                                      conf_thresh: float = 0.25,       # 더 관대하게
                                      adaptive_thresh: bool = True) -> np.ndarray:
    """전처리된 이미지에 최적화된 노이즈 제거"""
    H, W = pred_mask.shape
    total_pixels = H * W
    filtered_mask = np.zeros_like(pred_mask)

    for cls_id in np.unique(pred_mask):
        if cls_id == 0:
            continue

        class_mask = (pred_mask == cls_id).astype(np.uint8)
        num_labels, labels = cv2.connectedComponents(class_mask)

        if adaptive_thresh:
            class_confidences = single_probs[cls_id][class_mask == 1]
            if len(class_confidences) > 0:
                adaptive_conf_thresh = max(conf_thresh, np.percentile(class_confidences, 70))  # 70%로 완화
            else:
                adaptive_conf_thresh = conf_thresh
        else:
            adaptive_conf_thresh = conf_thresh

        for label_id in range(1, num_labels):
            component_mask = (labels == label_id)
            area = component_mask.sum()
            area_ratio = area / total_pixels

            if area_ratio >= min_area_ratio:
                filtered_mask[component_mask] = cls_id
            else:
                comp_confidences = single_probs[cls_id][component_mask]
                max_conf = comp_confidences.max() if comp_confidences.size > 0 else 0.0

                if max_conf >= adaptive_conf_thresh:
                    filtered_mask[component_mask] = cls_id

    return filtered_mask

def refine_mask_morphology(mask: np.ndarray, kernel_size: int = 3) -> np.ndarray:
    """전처리된 이미지용 가벼운 형태학적 연산"""
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kernel_size, kernel_size))
    opened = cv2.morphologyEx(mask.astype(np.uint8), cv2.MORPH_OPEN, kernel)
    closed = cv2.morphologyEx(opened, cv2.MORPH_CLOSE, kernel)
    return closed

def optimized_predict(batch, model, input_size=512, num_classes=7):
    """전처리된 이미지에 최적화된 예측 함수"""
    imgs = batch["pixel_values"].to(device)

    with torch.no_grad():
        outputs = model(pixel_values=imgs)
        logits = outputs.logits
        
        if logits.shape[-2:] != (input_size, input_size):
            logits = F.interpolate(logits, size=(input_size, input_size), mode="bilinear", align_corners=False)
        
        probs = F.softmax(logits, dim=1)

        # 전처리된 이미지는 더 관대한 후처리 적용
        filtered_pred_list = []
        for i in range(probs.shape[0]):
            single_probs = probs[i].cpu().numpy()
            pred_mask = np.argmax(single_probs, axis=0)

            # 1) 관대한 노이즈 제거
            filtered1 = remove_tiny_noise_with_confidence(
                pred_mask, single_probs,
                min_area_ratio=0.002,
                conf_thresh=0.25,
                adaptive_thresh=True
            )

            # 2) 가벼운 형태학적 연산
            filtered2 = refine_mask_morphology(filtered1, kernel_size=3)

            filtered_pred_list.append(torch.tensor(filtered2, device=device))

        pred = torch.stack(filtered_pred_list)

    return probs, pred

# ===== 시각화 함수들 =====

def mask_to_color_rgb(mask: np.ndarray) -> np.ndarray:
    """마스크를 컬러로 변환"""
    color_mask = np.zeros((*mask.shape, 3), dtype=np.uint8)
    for cid in range(len(class_colors_bright)):
        if cid in mask:
            color_mask[mask == cid] = class_colors_bright[cid]
    return color_mask

def add_labels(image, mask):
    """라벨 추가"""
    draw = ImageDraw.Draw(image)
    try:
        font = ImageFont.truetype(font_path, 18)
    except:
        font = ImageFont.load_default()

    for class_id in range(1, len(class_names)):
        class_mask = (mask == class_id)
        if not np.any(class_mask):
            continue

        y_coords, x_coords = np.where(class_mask)
        x_center = int(np.mean(x_coords))
        y_center = int(np.mean(y_coords))
        label = class_names[class_id]

        bbox = draw.textbbox((0, 0), label, font=font)
        text_w, text_h = bbox[2] - bbox[0], bbox[3] - bbox[1]
        padding = 10
        radius = 8
        
        box = [
            x_center - text_w//2 - padding,
            y_center - text_h//2 - padding,
            x_center + text_w//2 + padding,
            y_center + text_h//2 + padding
        ]
        
        draw.rounded_rectangle(box, radius=radius, fill="black")
        draw.text((x_center - text_w//2, y_center - text_h//2), label, fill="white", font=font)
        
    return image

def create_visualization(image, mask):
    """시각화 생성"""
    img_np = np.array(image)
    pred_color = mask_to_color_rgb(mask)
    
    # 오버레이 생성 (전처리된 이미지는 더 강한 오버레이)
    overlay = img_np.copy().astype(np.float32)
    mask_area = (mask > 0)
    overlay[mask_area] = (
        overlay[mask_area] * 0.3 + pred_color[mask_area] * 0.7  # 더 강한 마스크
    )
    overlay = overlay.astype(np.uint8)
    
    # 라벨 추가
    overlay = add_labels(Image.fromarray(overlay), mask)
    pred_color = add_labels(Image.fromarray(pred_color), mask)
    
    return pred_color, overlay

# ===== 메인 예측 함수 =====

def process_preprocessed_image(image_bytes):
    """전처리된 이미지 처리 (클라이언트에서 배경 정리된 상태)"""
    if model is None or processor is None:
        raise HTTPException(status_code=500, detail="모델이 로드되지 않았습니다")

    try:
        print("📸 전처리된 이미지 처리 시작...")
        
        # 1. 이미지 로드
        image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
        print(f"   원본 크기: {image.size}")
        
        # 2. 모델 입력 준비
        inputs = processor(images=image, return_tensors="pt")
        batch = {"pixel_values": inputs["pixel_values"]}
        print(f"   전처리 완료: {inputs['pixel_values'].shape}")
        
        # 3. 최적화된 예측 수행
        probs, pred = optimized_predict(
            batch, model, input_size=512, 
            num_classes=len(class_names)
        )
        
        final_pred = pred[0].cpu().numpy()
        
        # 4. 결과 분석
        unique, counts = np.unique(final_pred, return_counts=True)
        print("📊 예측 결과:")
        for u, c in zip(unique, counts):
            if u < len(class_names) and c > 100:  # 100픽셀 이상만 출력
                percentage = (c / final_pred.size) * 100
                print(f"   {class_names[u]}: {c:,}px ({percentage:.1f}%)")
        
        # 5. 원본 크기로 복원
        if final_pred.shape != (image.size[1], image.size[0]):
            final_pred = cv2.resize(
                final_pred.astype(np.uint8), 
                image.size, 
                interpolation=cv2.INTER_NEAREST
            )
        
        # 6. 시각화
        print("🎨 시각화 생성 중...")
        pred_img, overlay_img = create_visualization(image, final_pred)
        
        print("✅ 처리 완료!")
        return pred_img, overlay_img

    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"처리 중 오류: {str(e)}")

# ===== FastAPI 엔드포인트 =====

@app.post("/predict")
async def predict(file: UploadFile = File(...)):
    """전처리된 이미지를 받아서 segmentation 수행"""
    try:
        if not file.content_type.startswith("image/"):
            raise HTTPException(status_code=400, detail="이미지 파일만 업로드 가능합니다")

        print(f"📤 요청 받음: {file.filename} ({file.content_type})")
        
        image_bytes = await file.read()
        print(f"   파일 크기: {len(image_bytes):,} bytes")
        
        # 전처리된 이미지 처리
        pred_img, overlay_img = process_preprocessed_image(image_bytes)

        # 결과 인코딩
        pred_bytes = io.BytesIO()
        overlay_bytes = io.BytesIO()
        pred_img.save(pred_bytes, format="PNG", optimize=True)
        overlay_img.save(overlay_bytes, format="PNG", optimize=True)

        response = {
            "prediction": base64.b64encode(pred_bytes.getvalue()).decode("utf-8"),
            "overlay": base64.b64encode(overlay_bytes.getvalue()).decode("utf-8"),
            "status": "success",
            "message": "전처리된 이미지 처리 완료"
        }
        
        print("📤 응답 전송 완료")
        return response

    except Exception as e:
        print(f"❌ 오류 발생: {str(e)}")
        raise HTTPException(status_code=500, detail=f"처리 중 오류: {str(e)}")

@app.post("/predict-raw")
async def predict_raw(file: UploadFile = File(...)):
    """원본 이미지도 처리 가능 (호환성용)"""
    return await predict(file)

# ===== 서버 실행 =====

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    print(f"🚀 서버 시작: http://0.0.0.0:{port}")
    uvicorn.run("main:app", host="0.0.0.0", port=port, reload=False)