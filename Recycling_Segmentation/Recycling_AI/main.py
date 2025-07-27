from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image, ImageDraw, ImageFont, ImageEnhance
import torch
import torch.nn as nn
import torch.nn.functional as F
import numpy as np
import cv2
import io
import os
import uvicorn
import base64
import time

# ===== FastAPI 앱 생성 =====
app = FastAPI(title="Real-time Recycling Segmentation API")

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
        "message": "Real-time Recycling Segmentation API is running!",
        "version": "8.0",
        "features": ["pytorch_weights", "custom_model", "real_time_optimization"]
    }

@app.get("/health")
async def health():
    return {"status": "healthy", "gpu_available": torch.cuda.is_available()}

# ===== 모델 관련 설정 =====
# weights.pt 파일에서 직접 모델 로드

# ===== 모델 로드 =====
WEIGHTS_PATH = os.path.join(os.path.dirname(__file__), "weights.pt")

try:
    print("🤖 PyTorch 모델 로드 중...")
    
    if not os.path.exists(WEIGHTS_PATH):
        raise FileNotFoundError(f"weights.pt 파일을 찾을 수 없습니다: {WEIGHTS_PATH}")
    
    # 모델 직접 로드 (완전한 모델이 저장된 경우)
    model = torch.load(WEIGHTS_PATH, map_location='cpu')
    print(f"✅ 모델 파일 로드 완료!")
    
    # 모델 타입 확인
    print(f"   모델 타입: {type(model)}")
    
    # 평가 모드로 설정
    model.eval()
    
    # GPU 최적화
    if torch.cuda.is_available():
        model = model.cuda()
        print("✅ GPU 최적화 완료!")
    else:
        print("⚠️ CPU 모드로 실행")
    
    print("✅ 모델 로드 완료!")
    
except Exception as e:
    print(f"❌ 모델 로드 실패: {e}")
    print("💡 가능한 해결책:")
    print("   1. weights.pt 파일이 올바른 위치에 있는지 확인")
    print("   2. PyTorch 버전 호환성 확인")
    print("   3. 파일이 손상되지 않았는지 확인")
    model = None

# ===== 설정 =====
class_names = ["background", "can", "glass", "paper", "plastic", "styrofoam", "vinyl"]

class_colors_bright = [
    None,             # background - 투명
    (255, 69, 0),     # can - 선명한 주황
    (50, 205, 50),    # glass - 밝은 초록
    (30, 144, 255),   # paper - 밝은 파랑
    (255, 20, 147),   # plastic - 핫핑크
    (255, 215, 0),    # styrofoam - 골드
    (138, 43, 226)    # vinyl - 바이올렛
]

device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
print(f"🔧 디바이스: {device}")

font_path = os.path.join(os.path.dirname(__file__), "Pretendard-SemiBold.otf")

# 실시간 처리를 위한 설정
MODEL_INPUT_SIZE = 512  # 모델이 요구하는 크기에 맞게 조정
PROCESSING_TIMEOUT = 10.0  # 스마트폰 고해상도 이미지 처리 시간 고려

# ===== 전처리 함수 =====

def smart_preprocess_image(image, target_size=MODEL_INPUT_SIZE):
    """스마트폰 사진을 위한 지능형 전처리"""
    start_time = time.time()
    original_size = image.size
    width, height = original_size
    
    print(f"   원본 크기: {width}x{height}")
    
    # 1단계: 너무 큰 이미지는 먼저 축소 (메모리/속도 최적화)
    max_dimension = 2048
    if max(width, height) > max_dimension:
        scale = max_dimension / max(width, height)
        new_width = int(width * scale)
        new_height = int(height * scale)
        image = image.resize((new_width, new_height), Image.Resampling.LANCZOS)
        width, height = new_width, new_height
        print(f"   1차 축소: {width}x{height}")
    
    # 2단계: 스마트 크롭 (중앙 + 객체 중심)
    # 더 작은 차원을 기준으로 정사각형 크롭
    crop_size = min(width, height)
    
    # 중앙 크롭 (기본)
    left = (width - crop_size) // 2
    top = (height - crop_size) // 2
    
    # 스마트폰 사진 특성 고려한 조정
    if height > width:  # 세로 사진 (일반적인 스마트폰 사진)
        # 위쪽으로 약간 치우치게 (테이블 위 물건 촬영 고려)
        top = max(0, top - crop_size // 6)
    
    cropped = image.crop((left, top, left + crop_size, top + crop_size))
    print(f"   크롭 완료: {crop_size}x{crop_size}")
    
    # 3단계: 모델 입력 크기로 리사이즈
    resized = cropped.resize((target_size, target_size), Image.Resampling.LANCZOS)
    
    # 4단계: 이미지 품질 향상 (선택적)
    enhanced = enhance_image_quality(resized)
    
    # 5단계: 텐서 변환
    img_array = np.array(enhanced).astype(np.float32) / 255.0
    img_tensor = torch.from_numpy(img_array).permute(2, 0, 1).unsqueeze(0)
    
    if torch.cuda.is_available():
        img_tensor = img_tensor.cuda()
    
    elapsed = time.time() - start_time
    print(f"   스마트 전처리 완료: {elapsed:.3f}초")
    
    return img_tensor, original_size

def enhance_image_quality(image):
    """스마트폰 사진 품질 향상"""
    # 대비 및 선명도 향상 (분리수거 물품 구분에 도움)
    
    # 대비 향상
    contrast_enhancer = ImageEnhance.Contrast(image)
    image = contrast_enhancer.enhance(1.2)
    
    # 선명도 향상
    sharpness_enhancer = ImageEnhance.Sharpness(image)
    image = sharpness_enhancer.enhance(1.1)
    
    # 채도 약간 향상 (플라스틱, 캔 등 색상 구분에 도움)
    color_enhancer = ImageEnhance.Color(image)
    image = color_enhancer.enhance(1.1)
    
    return image

def preprocess_image(image, target_size=MODEL_INPUT_SIZE):
    """기존 함수 호환성 유지"""
    return smart_preprocess_image(image, target_size)

# ===== 모델 예측 =====

def predict_segmentation(image_tensor):
    """세그멘테이션 예측"""
    start_time = time.time()
    
    with torch.no_grad():
        # 모델 예측 (출력 형태는 모델에 따라 다를 수 있음)
        outputs = model(image_tensor)
        
        # 출력이 딕셔너리인지 텐서인지 확인
        if isinstance(outputs, dict):
            if "logits" in outputs:
                logits = outputs["logits"]
            elif "prediction" in outputs:
                logits = outputs["prediction"]
            else:
                # 첫 번째 값을 logits로 가정
                logits = list(outputs.values())[0]
        else:
            # 직접 텐서인 경우
            logits = outputs
        
        # 소프트맥스 적용
        probs = F.softmax(logits, dim=1)[0].cpu().numpy()
        prediction = np.argmax(probs, axis=0)
        confidence_map = np.max(probs, axis=0)
        
        print(f"   예측 완료 - Shape: {prediction.shape}")
        print(f"   감지된 클래스: {np.unique(prediction)}")
    
    elapsed = time.time() - start_time
    print(f"   모델 예측: {elapsed:.3f}초")
    
    return probs, prediction, confidence_map

# ===== 후처리 =====

def postprocess_prediction(prediction, confidence_map, confidence_threshold=0.3):
    """예측 결과 후처리"""
    start_time = time.time()
    
    # 신뢰도 기반 필터링
    mask = np.where(confidence_map >= confidence_threshold, prediction, 0)
    
    # Morphological operations로 노이즈 제거
    cleaned_mask = np.zeros_like(mask)
    
    for class_id in range(1, len(class_names)):
        class_mask = (mask == class_id).astype(np.uint8)
        
        if np.sum(class_mask) == 0:
            continue
        
        # 노이즈 제거
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        opened = cv2.morphologyEx(class_mask, cv2.MORPH_OPEN, kernel)
        
        # 작은 영역 제거
        if np.sum(opened) >= 50:
            cleaned_mask[opened > 0] = class_id
    
    elapsed = time.time() - start_time
    print(f"   후처리: {elapsed:.3f}초")
    
    return cleaned_mask

# ===== 시각화 =====

def create_visualization(image, mask):
    """시각화 생성"""
    start_time = time.time()
    
    img_np = np.array(image)
    
    # OVERLAY 생성
    overlay = img_np.copy().astype(np.float32)
    
    for class_id in range(1, len(class_names)):
        class_region = (mask == class_id)
        if np.any(class_region):
            color = class_colors_bright[class_id]
            overlay[class_region] = (
                img_np[class_region].astype(np.float32) * 0.6 +
                np.array(color) * 0.4
            )
    
    overlay = np.clip(overlay, 0, 255).astype(np.uint8)
    
    # PREDICT 생성
    predict = np.zeros_like(img_np)
    
    for class_id in range(1, len(class_names)):
        class_region = (mask == class_id)
        if np.any(class_region):
            predict[class_region] = class_colors_bright[class_id]
    
    # 라벨 추가
    overlay_pil = add_labels(Image.fromarray(overlay), mask)
    predict_pil = add_labels(Image.fromarray(predict), mask)
    
    elapsed = time.time() - start_time
    print(f"   시각화: {elapsed:.3f}초")
    
    return predict_pil, overlay_pil

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

        if np.sum(class_mask) < 100:  # 너무 작은 영역은 생략
            continue
        
        y_coords, x_coords = np.where(class_mask)
        x_center = int(np.mean(x_coords))
        y_center = int(np.mean(y_coords))
        
        label = class_names[class_id]
        
        # 텍스트 크기 계산
        bbox = draw.textbbox((0, 0), label, font=font)
        text_w = bbox[2] - bbox[0]
        text_h = bbox[3] - bbox[1]
        
        # 배경 박스
        padding = 4
        box_x1 = x_center - text_w//2 - padding
        box_y1 = y_center - text_h//2 - padding
        box_x2 = x_center + text_w//2 + padding
        box_y2 = y_center + text_h//2 + padding
        
        draw.rectangle([box_x1, box_y1, box_x2, box_y2], fill=(0, 0, 0))
        draw.text(
            (x_center - text_w//2, y_center - text_h//2), 
            label, 
            fill="white", 
            font=font
        )
        
    return image

# ===== 결과 분석 =====

def analyze_results(mask):
    """결과 분석"""
    detected_classes = []
    total_pixels = mask.size
    
    unique, counts = np.unique(mask, return_counts=True)
    
    for class_id, pixel_count in zip(unique, counts):
        if class_id > 0 and class_id < len(class_names):
            percentage = (pixel_count / total_pixels) * 100
            
            if percentage >= 0.5:  # 0.5% 이상만
                detected_classes.append({
                    'class': class_names[class_id],
                    'pixels': int(pixel_count),
                    'percentage': round(percentage, 1)
                })
    
    detected_classes.sort(key=lambda x: x['pixels'], reverse=True)
    class_names_only = [item['class'] for item in detected_classes]
    
    return class_names_only, detected_classes

# ===== 메인 처리 함수 =====

def process_segmentation(image_bytes):
    """메인 세그멘테이션 처리"""
    if model is None:
        raise HTTPException(status_code=500, detail="모델이 로드되지 않았습니다")

    total_start_time = time.time()
    
    try:
        print("🚀 세그멘테이션 처리 시작...")
        
        # 1. 이미지 로드
        image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
        print(f"   원본: {image.size}")
        
        # 2. 전처리
        image_tensor, original_size = preprocess_image(image)
        
        # 3. 예측
        probs, prediction, confidence_map = predict_segmentation(image_tensor)
        
        # 4. 후처리
        final_mask = postprocess_prediction(prediction, confidence_map)
        
        # 5. 결과 분석
        class_names_only, detailed_results = analyze_results(final_mask)
        
        # 6. 시각화
        predict_img, overlay_img = create_visualization(image, final_mask)
        
        total_elapsed = time.time() - total_start_time
        print(f"✅ 총 처리 시간: {total_elapsed:.3f}초")
        print(f"✅ 감지 결과: {class_names_only}")
        
        return predict_img, overlay_img, class_names_only, total_elapsed

    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"처리 중 오류: {str(e)}")

# ===== FastAPI 엔드포인트 =====

@app.post("/predict")
async def predict(file: UploadFile = File(...)):
    """세그멘테이션 수행"""
    try:
        if not file.content_type.startswith("image/"):
            raise HTTPException(status_code=400, detail="이미지 파일만 업로드 가능합니다")

        request_start = time.time()
        print(f"📤 요청 받음: {file.filename}")
        
        image_bytes = await file.read()
        print(f"   파일 크기: {len(image_bytes):,} bytes")
        
        # 세그멘테이션 처리
        predict_img, overlay_img, detected_classes, processing_time = process_segmentation(image_bytes)

        # 이미지 인코딩
        pred_bytes = io.BytesIO()
        overlay_bytes = io.BytesIO()
        
        predict_img.save(pred_bytes, format="PNG", optimize=True)
        overlay_img.save(overlay_bytes, format="PNG", optimize=True)

        # 응답 생성
        if detected_classes:
            main_class = detected_classes[0]
            confidence = 0.85
            message = f"처리 완료 ({processing_time:.2f}초)"
        else:
            main_class = "unknown"
            confidence = 0.1
            message = f"객체 미감지 ({processing_time:.2f}초)"

        response = {
            "prediction": base64.b64encode(pred_bytes.getvalue()).decode("utf-8"),
            "overlay": base64.b64encode(overlay_bytes.getvalue()).decode("utf-8"),
            "class": main_class,
            "confidence": confidence,
            "detected_classes": detected_classes,
            "processing_time": round(processing_time, 3),
            "status": "success",
            "message": message
        }
        
        total_time = time.time() - request_start
        print(f"📤 응답 완료: {total_time:.3f}초")
        
        return response

    except Exception as e:
        print(f"❌ 오류 발생: {str(e)}")
        raise HTTPException(status_code=500, detail=f"처리 중 오류: {str(e)}")

@app.post("/predict-raw")
async def predict_raw(file: UploadFile = File(...)):
    """호환성 엔드포인트"""
    return await predict(file)

# ===== 서버 실행 =====

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    print(f"🚀 서버 시작: http://0.0.0.0:{port}")
    uvicorn.run("main:app", host="0.0.0.0", port=port, reload=False)