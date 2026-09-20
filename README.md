# 🌿 Routine Finders (루틴 파인더스)

> **함께 습관을 만들어가는 루틴 챌린지 플랫폼**

루틴 파인더스는 개인의 성장을 돕고, 함께 도전하며 성취하는 즐거움을 나누는 루틴 관리 및 챌린지 플랫폼입니다.

[![Ruby](https://img.shields.io/badge/Ruby-3.4.0-red.svg)](https://www.ruby-lang.org/)
[![Rails](https://img.shields.io/badge/Rails-8.1.1-red.svg)](https://rubyonrails.org/)
[![License](https://img.shields.io/badge/License-Private-blue.svg)]()

---

## 📱 주요 기능

### 🎯 개인 루틴 관리
- 나만의 데일리 루틴 생성 및 관리
- 요일별 루틴 설정
- 루틴 완료 기록 및 통계
- 성취 지도 (캘린더 뷰)

### 🏆 챌린지 시스템
- 온라인/오프라인 챌린지 개설
- 보증금 기반 동기부여 시스템
- 실시간 인증 및 검증
- 참여자 랭킹 및 통계

### 👥 루파 클럽 (프리미엄 멤버십)
- 레벨 제한 없이 챌린지/모임 개설 가능
- 전용 패스 시스템 (휴식권, 세이브권)
- 주간/월간 성과 리포트 자동 생성
- 성장 포인트 적립

### ✨ 시너지 피드
- 멤버들의 성취 공유
- 응원 및 격려 시스템
- 실시간 활동 피드

### 🏅 배지 & 레벨 시스템
- 다양한 성취 배지
- 레벨 기반 권한 시스템
- 마일스톤 추적

---

## 🛠️ 기술 스택

### Backend
- **Ruby** 3.4.0
- **Rails** 8.1.1
- **SQLite3** (개발/프로덕션)
- **Solid Queue** (백그라운드 작업)
- **Solid Cache** (캐싱)

### Frontend
- **Hotwire** (Turbo + Stimulus)
- **TailwindCSS** 3.x
- **Importmap** (JavaScript 관리)

### Authentication
- **OmniAuth** (소셜 로그인)
  - 카카오 로그인
  - 구글 로그인
  - Threads 로그인

### Security
- **Rack::Attack** (Rate Limiting)
- 파일 업로드 검증 (Magic Number)
- CSRF 보호

### Deployment
- **Mac Studio + OrbStack + Docker Compose** (ARM64 운영)
- **Cloudflare Tunnel** (공개 HTTPS), **Tailscale + SSH** (관리 접속)
- **Thruster** (HTTP 캐싱/압축)
- **launchd** (Tunnel 및 정기 백업 실행)

---

## 🚀 시작하기

### 필수 요구사항

- Ruby 3.4.0 이상
- Node.js 18.x 이상
- SQLite3

### 설치

```bash
# 저장소 클론
git clone https://github.com/wonyteria/routine-finders.git
cd routine-finders

# 의존성 설치
bundle install

# 환경변수 설정
cp .env.example .env
# .env 파일을 열어 OAuth 키 등을 설정하세요

# 데이터베이스 설정
rails db:create
rails db:migrate
rails db:seed

# 개발 서버 실행
./bin/dev
```

서버가 실행되면 `http://localhost:3000`에서 확인할 수 있습니다.

### 프로토타입 앱 접속

프로토타입 앱은 `/prototype` 경로로 접속할 수 있습니다:
- 홈: `http://localhost:3000/prototype/home`
- 탐색: `http://localhost:3000/prototype/explore`
- 로그인: `http://localhost:3000/prototype/login`

---

## 📁 프로젝트 구조

```
routine-finders/
├── app/
│   ├── controllers/
│   │   ├── prototype_controller.rb    # 프로토타입 앱 메인 컨트롤러
│   │   ├── challenges_controller.rb   # 챌린지 관리
│   │   └── ...
│   ├── models/
│   │   ├── user.rb                    # 사용자 모델
│   │   ├── challenge.rb               # 챌린지 모델
│   │   ├── participant.rb             # 참여자 모델
│   │   └── ...
│   ├── services/                      # 비즈니스 로직 서비스
│   │   ├── challenge_participation_service.rb
│   │   ├── routine_club_report_service.rb
│   │   └── file_upload_validator.rb
│   ├── views/
│   │   ├── layouts/
│   │   │   └── prototype.html.erb     # 프로토타입 레이아웃
│   │   ├── prototype/                 # 프로토타입 뷰
│   │   └── ...
│   └── javascript/
│       └── controllers/               # Stimulus 컨트롤러
├── config/
│   ├── initializers/
│   │   └── rack_attack.rb            # Rate Limiting 설정
│   └── deploy.yml                    # Kamal 배포 설정
└── db/
    ├── migrate/                      # 마이그레이션 파일
    └── seeds.rb                      # 시드 데이터
```

---

## 🔐 환경변수 설정

`.env` 파일에 다음 환경변수를 설정하세요:

```env
# Google OAuth
GOOGLE_CLIENT_ID=your_google_client_id
GOOGLE_CLIENT_SECRET=your_google_client_secret

# Kakao OAuth
KAKAO_CLIENT_ID=your_kakao_client_id
KAKAO_CLIENT_SECRET=your_kakao_client_secret

# Threads OAuth (Optional)
THREADS_CLIENT_ID=your_threads_client_id
THREADS_CLIENT_SECRET=your_threads_client_secret

# Rails Master Key (프로덕션)
RAILS_MASTER_KEY=your_master_key
```

---

## 🧪 테스트

```bash
# 전체 테스트 실행
rails test

# 특정 테스트 파일 실행
rails test test/models/user_test.rb

# 시스템 테스트 실행
rails test:system
```

---

## 📦 배포

### Mac Studio 운영

운영 도메인은 `https://www.routinefinders.life`이며, 루트 도메인은 경로와 쿼리를 보존해 `www`로 리다이렉트합니다. Cloudflare Tunnel은 Mac 호스트의 `http://127.0.0.1:13200`으로 연결하고, Compose는 이 포트를 컨테이너의 80번 포트에 연결합니다.

운영 디렉터리는 `/Users/Hyphen/services/routine-finders`입니다. 저장소 checkout은 하위 `source/`에 두고, 운영용 `compose.macstudio.yml`과 `deploy/` 파일은 운영 디렉터리에 별도로 배치합니다. 저장소를 pull하는 것만으로 실행 중인 앱이나 운영 스크립트가 갱신되지는 않습니다.

- 운영 데이터 볼륨: `routine_finders_storage_macstudio`
- 운영 환경변수: `runtime.env` — 비밀값 포함, 권한 `0600`, Git 제외
- Tunnel 토큰: `tunnel.token` — 권한 `0600`, Git 제외
- 실행할 이미지: `deploy/release.env`의 `RF_IMAGE` — 검증한 버전으로 고정, Git 제외
- `deploy/*.plist`는 위 계정과 절대 경로를 사용하는 Mac 전용 launchd 설정입니다.

Mac에 SSH로 접속한 뒤 운영 디렉터리에서 상태를 확인합니다.

```bash
cd ~/services/routine-finders

docker compose --env-file deploy/release.env -f compose.macstudio.yml ps
docker compose --env-file deploy/release.env -f compose.macstudio.yml logs --tail=100 web
```

기존 `.github/workflows/deploy.yml`과 `set_super_admin.yml`은 DigitalOcean/Kamal을 대상으로 하므로 GitHub에서 비활성화했습니다. **현재 `main` 푸시는 자동 배포가 아니며, Mac용 CI/CD는 아직 구성하지 않았습니다. 기존 워크플로를 그대로 재활성화하지 마세요.**

### 정기 백업과 복원

`life.routinefinders.backup` LaunchAgent는 매시 17분과 사용자 로그인 시 실행합니다. 로그아웃 상태나 OrbStack 미실행 상태에서는 정상 백업을 보장하지 않습니다.

- SQLite 4개를 온라인 백업한 뒤 업로드 파일과 복구용 설정을 함께 보관합니다.
- 매번 압축본을 다시 풀어 파일 SHA256, DB 무결성·테이블별 건수, 첨부파일 크기·체크섬을 검증합니다.
- 각 DB는 독립된 온라인 스냅샷입니다. 여러 DB에 걸친 동일 시점의 원자적 스냅샷은 아닙니다.
- 보관 정책은 **최근 24시간 전체 + 최신 일별 7개 + 주별 4개 + 월별 3개**의 합집합이며, 날짜 기준은 `Asia/Seoul`입니다.
- 새 백업 검증 후에만 `backups/managed/` 안의 소유권이 확인된 백업을 정리합니다. 이전 백업과 다른 디렉터리는 삭제하지 않습니다.
- 용량 상한은 없습니다. 남은 디스크 공간이 1GiB 미만이면 백업과 정리를 중단합니다.
- 실패 상태·로그를 기록하고 첫 실패 시 macOS 알림을 시도합니다. 알림 수신은 macOS 권한에 달려 있습니다.
- **비밀값을 포함한 로컬 비암호화 백업**입니다. 디렉터리 `0700`, 아카이브 `0600`으로 접근을 제한하지만 Mac 고장·디스크 손실을 대비한 외부 백업은 아닙니다.

운영 디렉터리에서 다음 명령을 사용합니다.

```bash
python3 deploy/backup.py status
python3 deploy/backup.py backup
python3 deploy/backup.py list
python3 deploy/backup.py verify --help
python3 deploy/backup.py restore --help
```

`status`는 최근 성공이 2시간을 넘겼거나 실패한 경우 비정상 종료 코드를 반환합니다. 주 로그는 `logs/backup.log`이며 2MiB 단위로 이전 로그 3개까지 순환합니다.

`restore`는 검증한 백업을 **존재하지 않는 새 디렉터리로만** 내보냅니다. 운영 볼륨을 자동으로 교체하지 않습니다. 실제 운영 복원은 앱·작업 프로세스 중단, 별도 볼륨 복원, 검증을 거쳐 수동 전환해야 합니다.

백업 도구 테스트는 저장소 checkout에서 실행합니다. 운영 DB에 접근하지 않는 임시 데이터 테스트입니다.

```bash
python3 -m unittest discover -s deploy -p test_backup.py -v
```

---

## 🎨 디자인 시스템

### 색상 팔레트
- **Primary**: Indigo (#7C4DFF)
- **Success**: Emerald (#10B981)
- **Warning**: Amber (#F59E0B)
- **Danger**: Rose (#F43F5E)
- **Background**: Dark (#0C0B12)

### 타이포그래피
- **Font Family**: Pretendard (한글), Outfit (영문)
- **Font Weights**: 400 (Regular), 700 (Bold), 900 (Black)

---

## 🤝 기여하기

이 프로젝트는 개인 프로젝트이지만, 피드백과 제안은 언제나 환영합니다!

---

## 📄 라이선스

이 프로젝트는 비공개 프로젝트입니다. 무단 복제 및 배포를 금지합니다.

---

## 👨‍💻 개발자

**Cyberneum** - 루틴 파인더스 창립자 & 개발자

---

## 📞 문의

프로젝트에 대한 문의사항이 있으시면 이슈를 등록해주세요.

---

**Made with ❤️ by Routine Finders Team**
