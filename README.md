# DUEL — 서부극 모바일 심리전 대전 게임

## 폴더 구조
```
duel/
├─ index.html          게임 본체 (로컬 대전 · 로봇 대전 · 온라인 대전)
├─ config.js           ★ 나중에 Supabase 주소/키를 입력하는 파일
├─ duel-offline.html   온라인 기능이 없는 단독 버전 (인터넷 없이도 실행)
├─ supabase/
│  └─ setup.sql        Supabase 데이터베이스 설정 (테이블·보안 정책·서버 함수)
└─ README.md           이 문서
```
빌드 도구나 설치가 필요 없는 정적 파일입니다.

## 1단계: 내 컴퓨터에서 실행 (온라인 설정 없이)
- 가장 쉬운 방법: `index.html`을 더블클릭해 브라우저로 엽니다. 로컬 1대1, 로봇 대전을 바로 플레이할 수 있습니다.
- 온라인 대전까지 테스트하려면 간단한 웹 서버로 엽니다.
  1. 이 폴더에서 터미널(Windows는 PowerShell)을 엽니다.
  2. `python3 -m http.server 8000` (Windows는 `py -m http.server 8000`)
  3. 브라우저에서 `http://localhost:8000` 접속
- 휴대폰 테스트는 아래 배포 후 주소로 접속하는 것이 가장 쉽습니다. 소리는 시작 버튼을 누른 뒤 켜집니다.

## 2단계: Supabase 설정 (온라인 대전을 쓸 때만)
1. https://supabase.com 에서 가입 후 **New project**를 만듭니다. 이름, DB 비밀번호(따로 보관), 지역을 고릅니다.
2. 왼쪽 메뉴 **Authentication → Sign In / Providers**에서 **Anonymous Sign-Ins**를 켭니다.
3. **SQL Editor → New query**에 `supabase/setup.sql` 내용 전체를 붙여넣고 **Run**을 누릅니다. (`publication`에 이미 있다는 오류가 나면 `alter publication` 줄만 지우고 다시 실행)
4. **Project Settings → API**에서 **Project URL**과 **anon public** 키를 복사합니다.
5. `config.js`를 메모장으로 열어 `SB_URL`, `SB_KEY` 따옴표 안에 붙여넣고 저장합니다.
   - **service_role 키는 절대 넣지 마세요.** anon 키는 공개되어도 보안 정책(RLS)이 보호하도록 설계되어 있습니다.
6. 게임을 다시 열면 메뉴의 "온라인 대전"이 동작합니다.

## 3단계: 인터넷에 배포 (택1, 모두 무료 플랜 있음)
**Netlify (가장 쉬움)**: https://app.netlify.com/drop 에 `duel` 폴더 전체를 끌어다 놓으면 주소가 생깁니다. 파일을 고치면 같은 방법으로 다시 올립니다.

**GitHub Pages**: GitHub 저장소를 만들고 폴더 내용을 업로드 → Settings → Pages → Branch를 `main`/root로 선택.

**Cloudflare Pages**: Pages → Create project → Direct Upload로 폴더 업로드.

배포 주소는 HTTPS여야 하며, 휴대폰 두 대에서 같은 주소를 열면 온라인 대전을 할 수 있습니다.

## 4단계: 온라인 대전 테스트 (일반 창 + 시크릿 창)
1. A: 온라인 대전 → 방 만들기 → 5자리 코드 확인
2. B: 온라인 대전 → 코드 입력 → 참가 → 양쪽에서 인트로 후 턴 시작
3. 한쪽만 선택하면 상대 화면에 선택이 보이지 않고, 둘 다 선택하면 동시에 모션이 재생되는지 확인
4. 한쪽이 선택하지 않고 시간이 끝나면 그쪽만 턴 넘김으로 처리되는지 확인
5. 동시 쏘기 → 무승부 → 재대결에서 장전/방어 모션이 보이지 않고 "상대방이 턴을 넘겼습니다"만 표시되는지 확인
6. B 탭을 닫으면 A에 연결 끊김 메시지, B가 다시 열어 "마지막 방 재접속"으로 복귀되는지 확인

## 보안 요약
- 선택한 행동·탄약은 클라이언트가 직접 읽을 수 없고, 판정·타이머·재대결·동전 던지기는 서버 함수가 처리합니다.
- 프런트엔드에는 공개용 anon 키만 사용합니다.
- 오래된 방 정리, 익명 계정 남용 방지(CAPTCHA·Rate limit)는 Supabase 대시보드에서 따로 설정하세요.

## 주의
- 온라인 모드는 실제 Supabase 프로젝트로 아직 검증되지 않았습니다. 4단계 테스트로 먼저 확인하세요.
- 채팅 미리보기 화면처럼 외부 서버 접속이 막힌 환경에서는 온라인 대전이 동작하지 않습니다.
