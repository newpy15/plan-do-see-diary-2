# 인증 확인 기록

- 실행 시각(서울): 2026-11-04 10:55:15
- 서버: https://gwxllisihhugupgyanys.supabase.co
- 계정 A: n***@naver.com / 계정 B: r***@naver.com (비밀번호는 기록하지 않음)

**결과: ✅ 29개 통과 / ❌ 0개 실패**

## 1. 가입 중복과 로그인 실패 문구

- 이미 있는 이메일로 다시 가입: `POST /auth/v1/signup` → **422** User already registered
- ✅ 같은 이메일로 두 번 가입되지 않는다 — 상태 422
- 아이디는 맞고 비밀번호가 틀림: `POST /auth/v1/token` → **400** Invalid login credentials
- 아이디 자체가 없음: `POST /auth/v1/token` → **400** Invalid login credentials
- ✅ 두 경우의 상태와 안내 문구가 같다 — 400 / "Invalid login credentials"

## 2. 로그인 값(토큰)의 모습

- 로그인 응답의 access_token: `eyJhbGci…[가림]` (앞 8글자만 보임)
- 만료까지: 3600초 (60분) · 발급 시각 2026-11-04 10:55:19 (서울) · 세션 번호(session_id) 포함: 예
- ✅ 만료 시각이 들어 있다
- ✅ 요청에 쓰는 값은 헤더(Authorization)에만 실리고 주소(URL)에는 없다 — 위 모든 요청이 주소에 토큰 없이 보내짐

## 3. 계정 두 개에 자료 넣기

- 계정 A: 계획 1·할 일 1·실행 기록 1 (ID P-9715aeff, T-da07f617) / 계정 B: 같은 모양 (ID P-0a516472, T-5888128b). 비밀번호는 적지 않음.

## 4. 한 계정으로 로그인해서 다른 계정의 자료를 읽기·고치기·지우기

- A→B 읽기: `POST /rest/v1/rpc/todo_get` → **404** 할 일을 찾을 수 없습니다.
- ✅ A→B 읽기 요청이 거절된다 — 상태 404
- A→B 고치기: `POST /rest/v1/rpc/todo_update` → **404** 할 일을 찾을 수 없습니다.
- ✅ A→B 고치기 요청이 거절된다 — 상태 404
- A→B 지우기: `POST /rest/v1/rpc/todo_delete` → **404** 할 일을 찾을 수 없습니다.
- ✅ A→B 지우기 요청이 거절된다 — 상태 404
- A→B 계획 고치기: `POST /rest/v1/rpc/plan_update` → **404** 계획을 찾을 수 없습니다.
- ✅ A→B 계획 고치기 요청이 거절된다 — 상태 404
- A→B 계획 지우기: `POST /rest/v1/rpc/plan_delete` → **404** 계획을 찾을 수 없습니다.
- ✅ A→B 계획 지우기 요청이 거절된다 — 상태 404
- A→B 실행 기록 지우기: `POST /rest/v1/rpc/log_delete` → **404** 기록을 찾을 수 없습니다.
- ✅ A→B 실행 기록 지우기 요청이 거절된다 — 상태 404
- A→B 완료 처리: `POST /rest/v1/rpc/complete_todo` → **404** 할 일을 찾을 수 없습니다.
- ✅ A→B 완료 처리 요청이 거절된다 — 상태 404
- B→A 읽기: `POST /rest/v1/rpc/todo_get` → **404** 할 일을 찾을 수 없습니다.
- ✅ B→A 읽기 요청이 거절된다 — 상태 404
- B→A 고치기: `POST /rest/v1/rpc/todo_update` → **404** 할 일을 찾을 수 없습니다.
- ✅ B→A 고치기 요청이 거절된다 — 상태 404
- B→A 지우기: `POST /rest/v1/rpc/todo_delete` → **404** 할 일을 찾을 수 없습니다.
- ✅ B→A 지우기 요청이 거절된다 — 상태 404
- B→A 계획 고치기: `POST /rest/v1/rpc/plan_update` → **404** 계획을 찾을 수 없습니다.
- ✅ B→A 계획 고치기 요청이 거절된다 — 상태 404
- B→A 계획 지우기: `POST /rest/v1/rpc/plan_delete` → **404** 계획을 찾을 수 없습니다.
- ✅ B→A 계획 지우기 요청이 거절된다 — 상태 404
- B→A 실행 기록 지우기: `POST /rest/v1/rpc/log_delete` → **404** 기록을 찾을 수 없습니다.
- ✅ B→A 실행 기록 지우기 요청이 거절된다 — 상태 404
- B→A 완료 처리: `POST /rest/v1/rpc/complete_todo` → **404** 할 일을 찾을 수 없습니다.
- ✅ B→A 완료 처리 요청이 거절된다 — 상태 404
- ✅ 거절은 403 또는 존재를 감추는 404 로 이뤄졌다 — 상태 목록: 404
- 거절 앞뒤 건수 — A: {"plans":1,"todos":1,"exec_logs":1} → {"plans":1,"todos":1,"exec_logs":1} / B: {"plans":1,"todos":1,"exec_logs":1} → {"plans":1,"todos":1,"exec_logs":1}
- ✅ 거절 앞뒤로 양쪽 자료 건수가 같고 새로 생긴 자료가 없다
- ✅ 반대편(B)의 자료는 그대로다

## 5. 주소·요청 헤더·요청 본문에 다른 계정을 적어 보낸 요청

- 헤더에 `X-User-Id: <B>` 를 적고 A의 로그인 값으로 목록 요청: **200**, 돌아온 할 일 1건
- ✅ 헤더에 남의 계정을 적어도 A의 자료만 돌아온다(B의 ID 없음)
- 주소에 `?user_id=eq.<B>` 를 붙여 A의 로그인 값으로 목록 요청: `POST /rest/v1/rpc/todo_list?user_id=eq.<B>` → **400** column todo_list.user_id does not exist
- ✅ 주소에 남의 계정을 적은 요청은 거절되거나, 돌아와도 A의 자료뿐이다 — 상태 400
- 본문에 `user_id: <B>` 를 몰래 끼워 A가 계획 만들기: `POST /rest/v1/rpc/plan_create` → **404** Could not find the function diary2.plan_create(p_category, p_criteria, p_end, p_estimated,…
- ✅ 남의 계정 번호를 본문에 적어도 받아들이지 않는다

## 6. 로그인하지 않은 채, 또는 표에 직접 요청

- 로그인 값 없이(공개용 키만) 목록 요청: `POST /rest/v1/rpc/todo_list` → **401** permission denied for function todo_list
- 로그인 값 없이 표를 직접 읽기: `GET /rest/v1/todos?select=*` → **401** permission denied for table todos
- 로그인했어도 표를 직접 읽기(함수를 거치지 않음): `GET /rest/v1/todos?select=*` → **403** permission denied for table todos
- ✅ 로그인 없이 직접 요청하면 거절된다(401/403)
- ✅ 로그인했어도 표를 직접 읽을 수 없다
- ✅ A의 목록 응답에 B의 자료가 하나도 없다 — A의 할 일 1건

## 7. 로그아웃 전과 후, 같은 주소·같은 방식으로 요청


| | 요청 | 로그인 값 | 응답 |
|---|---|---|---|
| 로그아웃 전 | `POST /rest/v1/rpc/plans_list` | `eyJhbGci…[가림]` | **200** [] |
| 로그아웃 요청 | `POST /auth/v1/logout` | 같은 값 | **204** |
| 로그아웃 후 | `POST /rest/v1/rpc/plans_list` | `eyJhbGci…[가림]` (같은 값) | **401** 로그아웃했거나 만료된 로그인 값입니다. 다시 로그인하세요. |
- ✅ 로그아웃 전에는 성공(200)
- ✅ 로그아웃 뒤 같은 값으로 다시 요청하면 거절(401) — 두 요청의 다른 점은 그 사이에 로그아웃했다는 것뿐
