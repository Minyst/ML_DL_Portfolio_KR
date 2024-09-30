# 🎓 Data Scientist Portfolio

---

## 📊 Project

### Project 1: Credit Card Fraud Detection

**Objective** <br/>
어떤 모델이 데이터를 축소하거나 증강하였을때 가장 뛰어난 검출능력을 보이는지 확인하였습니다.

**Technologies Used** <br/>
- Dimensionality Reduction: PCA, tSNE, UMAP
- Dimensionality Augmentation: SMOTE, BorderLineSMOTE, ADASYN
- Machine Learning Models: RandomForest, XGBoost, CatBoost, LightGBM
- Deep Learning Models: TensorFlow, Pytorch 

**Key Results** <br/>
Dimesionality Reduction과 Augmentation 중에 뭐가 더 모델의 성능에 좋을까 비교해보기 위해서 
다양한 머신러닝 모델과 딥러닝 모델을 활용하였습니다. 
그 결과 어떤 방식으로 어떤 모델을 사용했을때 가장 성능이 좋은지 순위표를 만들 수 있었습니다.

**URL** <br/>
https://www.kaggle.com/datasets/mlg-ulb/creditcardfraud

---

### Project 2: YOLOv10 Pretrained model vs Custom model

**Objective** <br/>
Pretrained YOLOv10과 Custom YOLOv10중 어떤 것이 더 성능이 좋은지 비교합니다.

**Technologies Used** <br/>

- Model: YOLOv10
- Package: ultralytics, supervision, cv2

**Key Results** <br/>
비디오를 캡처한 후 여러 프레임을 생성하였고 <br/>
각 프레임을 모델로 학습시킨 후, 이러한 프레임들을 다시 하나의 비디오로 만들었습니다. <br/>
Pretrained model의 경우, 모델을 그대로 사용하여 예측을 수행했지만 <br/>
Custom model의 경우, 기존의 YOLOv10 가중치를 사용하여 준비된 데이터를 학습시키고, <br/>
그 결과 나온 최고의 가중치를 최종 모델의 가중치로 선택한 후 이를 예측에 사용했습니다. <br/>
이 과정은 릴레이 레이스와 비슷합니다.

Pretrained model과 Custom model을 비교했을 때, 상당한 차이가 있었습니다. <br/>
다양한 클래스의 이미지로 지속적으로 학습된 Custom model은 자동으로 인식하는 Pretrained model보다 <br/>
클래스 예측 범위가 더 넓었지만, 정확도는 Pretrained model에 비해 훨씬 낮았습니다.

**URL** <br/>
https://github.com/THU-MIG/yolov10 <br/>
https://docs.ultralytics.com/ko/models/yolov10

---

### Project 3: Detectron2 Pretrained model vs Custom model

**Objective** <br/>
Pretrained detectron2와 Custom detectron2중 어떤 것이 더 성능이 좋은지 비교합니다.

**Technologies Used** <br/>
- Model: Detectron2
- Package: detectron2, cv2

**Key Results** <br/>
detectron2는 yolov10이랑 거의 똑같지만 차이점이 두가지 있습니다.
첫번째, detectron2는 yolov10과 달리 faster_rcnn weights를 사용합니다.
두번째, yolov10에서는 pretrained와 custom이 결과가 조금 다르게 나왔지만 
detectron은 차이가 느껴지지 않았습니다.

**URL** <br/>
https://github.com/facebookresearch/detectron2/blob/main/README.md

---

### Project 4: AI Cover - RVC

**Objective** <br/>
RVC 모델을 활용해 한 가수의 목소리로 다른 가수의 노래를 부르게 하는 것 

**Technologies Used** <br/>
- Model: RVC

**Key Results** <br/>
이 프로젝트는 5가지 과정으로 나누어서 설명할 수 있습니다.
첫번째, 다운받아온 youtube music을 음성과 배경음악으로 split합니다.
두번째, 모델이 더 잘 학습할 수 있도록 음성을 여러개로 slice합니다.
세번째, RVC_pretrained를  download하고.
네번째, train합니다.
다섯번째, 가수가 다른 노래를 부르는 음악파일을 생성합니다.

생각보다 자연스러운 음악이 생성되어서 놀라웠습니다.
디테일한 설정도 할 수 있는데 전문가가 있다면 더욱 더 싱크로율과 완성도가 높아질 것으로 기대됩니다.

**URL** <br/>
https://github.com/facebookresearch/demucs <br/>
https://github.com/openvpi/audio-slicer

---

### Project 5: CNN - CIFAR-10

**Objective** <br/>
CIFAR-10 데이터를 활용해서 
Tensorflow와 Pytorch로 복잡한 CNN 구성해보기

**Technologies Used** <br/>
- Models : TensorFlow, Pytorch
- CNN Process : Data Augmentation, Conv2d, Padding, Batch Normalization, Pooling, Dropout, Flatten 

**Key Results** <br/>
Tensorflow와 Pytorch로 할 수 있는 CNN의 모든 과정을 담았습니다.

**URL** <br/>
https://www.cs.toronto.edu/~kriz/cifar.html

---

### Project 6: CLIP

**Objective** <br/>
웹 이미지와 컴퓨터에 저장된 이미지를 대상으로 CLIP 모델(Zero-shot image classification model)을 사용하는 방법을 알아내는 것.

**Technologies Used** <br/>

Zero-shot image classification은 모델이 특정 클래스의 이미지를 훈련 중에 직접 학습하지 않았더라도 새로운 이미지를 정확하게 분류할 수 있는 기술입니다. 모델은 학습된 다른 클래스 간의 유사성 또는 관계와 사전에 학습된 지식을 활용하여 새로운 클래스를 추론합니다.

CLIP(Contrastive Language-Image Pretraining)은 Zero-shot image classification의 대표적인 모델입니다. CLIP은 이미지와 텍스트를 동시에 학습하여 두 가지 간의 관계를 이해할 수 있게 합니다. CLIP은 대조적 학습을 사용하여 이미지와 해당 이미지의 텍스트 설명을 짝지어 학습합니다. 이를 통해 모델은 이전에 보지 못한 클래스도 적절한 텍스트 설명과 연결하여 효과적으로 분류할 수 있습니다.

**Key Results** <br/>
CLIP에 의해 예측된 웹 이미지와 컴퓨터에 저장된 이미지의 결과.

**URL** <br/>
https://github.com/openai/CLIP

---

### Project 7: SAM2

**Objective** <br/>
YOLO를 사용해 객체를 탐지한 후, SAM2를 사용해 탐지된 객체의 세그멘테이션 마스크를 생성하고 이후에 각 객체에 맞는 색상으로 마스크를 오버레이하여 출력 영상을 생성합니다. YOLO는 바운딩 박스를 생성하고, SAM은 이를 기반으로 세그멘테이션을 처리하여 연동합니다.

**Technologies Used** <br/>
- Models: SAM2, YOLO

**Key Results** <br/>
모델로 탐지된 새로운 영상

**URL** <br/>
https://github.com/facebookresearch/segment-anything-2 <br/>
https://docs.ultralytics.com/ko/models/yolov10

---

## 📈 Skills

- **Programming Languages**: Python
- **Data Preprocessing**: Pandas, NumPy
- **Data Visualization**: Matplotlib
- **Machine Learning & Deep Learning**: Scikit-Learn, TensorFlow, Pytorch, OpenCV
- **Databases**: 
- **Tools**: Jupyter Notebook, Google Colab

---

## 🛠️ Tools & Technologies

<p>
  <img src="https://img.shields.io/badge/Tensorflow-FF6F00.svg?style=for-the-badge&logo=Tensorflow&logoColor=white" alt="Tensorflow" width="120" height="30"/>
  <img src="https://img.shields.io/badge/Pytorch-EE4C2C.svg?style=for-the-badge&logo=pytorch&logoColor=white" alt="Pytorch" width="120" height="30"/>
  <img src="https://img.shields.io/badge/OpenCV-5C3EE8.svg?style=for-the-badge&logo=OpenCV&logoColor=white" alt="OpenCV" width="120" height="30"/>
</p>

---




