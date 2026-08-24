from pathlib import Path
from xml.sax.saxutils import escape

OUT = Path(__file__).parent

STYLE = """<style>
.h{font:700 24px 'Apple SD Gothic Neo','Noto Sans KR',Arial;fill:#1643d8}.t{font:700 19px 'Apple SD Gothic Neo','Noto Sans KR',Arial;fill:#17233d}.p{font:500 15px 'Apple SD Gothic Neo','Noto Sans KR',Arial;fill:#516078}.s{font:600 14px 'Apple SD Gothic Neo','Noto Sans KR',Arial;fill:#5533a7}.w{font:700 15px 'Apple SD Gothic Neo','Noto Sans KR',Arial;fill:#fff}</style>"""

def frame(title: str, subtitle: str, headings: list[str]) -> list[str]:
    head = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1800" height="1800" viewBox="0 0 1800 1800">',
        '<defs><marker id="a" markerWidth="10" markerHeight="10" refX="9" refY="3" orient="auto"><path d="M0 0L0 6L9 3z" fill="#2747b7"/></marker><filter id="s"><feDropShadow dx="0" dy="7" stdDeviation="8" flood-color="#1e3a8a" flood-opacity=".10"/></filter>', STYLE, '</defs>',
        '<rect width="1800" height="1800" fill="#fff"/><g transform="translate(0 220)">',
        f'<text x="80" y="55" style="font:700 34px Apple SD Gothic Neo,Noto Sans KR,Arial;fill:#13265b">{escape(title)}</text>',
        f'<text x="80" y="89" style="font:500 17px Apple SD Gothic Neo,Noto Sans KR,Arial;fill:#64748b">{escape(subtitle)}</text>',
        '<rect x="320" y="115" width="1410" height="700" rx="28" fill="#fbfdff" stroke="#5379ff" stroke-width="2" stroke-dasharray="9 7"/>'
    ]
    xs = [80, 385, 690, 1040, 1390]
    for x, label in zip(xs, headings):
        head.append(f'<text x="{x}" y="150" class="h">{escape(label)}</text>')
    return head

def box(x, y, w, h, title, lines, fill="#fff", stroke="#dbe5ff"):
    parts = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="18" fill="{fill}" stroke="{stroke}" stroke-width="2" filter="url(#s)"/>', f'<text x="{x+w/2}" y="{y+36}" text-anchor="middle" class="t">{escape(title)}</text>']
    for i, line in enumerate(lines):
        parts.append(f'<text x="{x+w/2}" y="{y+64+i*25}" text-anchor="middle" class="p">{escape(line)}</text>')
    return ''.join(parts)

def arrow(x1, y1, x2, y2, dashed=False, color="#2747b7"):
    dash = ' stroke-dasharray="8 7"' if dashed else ''
    return f'<path d="M{x1} {y1} L{x2} {y2}" stroke="{color}" stroke-width="3"{dash} marker-end="url(#a)"/>'

def close(parts):
    parts += ['<text x="1025" y="790" text-anchor="middle" class="h">GCP 프로젝트</text>', '</g></svg>']
    return '\n'.join(parts)

def infrastructure():
    p = frame('CouponKok · Terraform IaC 인프라 아키텍처', '코드로 재현하는 런타임 경계 · 최소 권한 IAM · 비밀값 미기록', ['1 Repository', '2 Terraform', '3 Compute', '4 Data · Operations', '5 Security'])
    p += [
        box(75, 195, 210, 530, 'GitHub Repository', ['infra/terraform', '변수 · 모듈 · 정책', 'Secret 값 제외'], '#f7faff'),
        box(365, 195, 245, 530, 'Terraform Plan / Apply', ['변경 계획 검토', '상태 파일 별도 관리', '수동 콘솔 차이 탐지'], '#eef4ff', '#9db6ff'),
        box(680, 195, 280, 140, 'Cloud Run API', ['api runtime service account', 'Firebase Token 검증'], '#eef4ff'),
        box(680, 370, 280, 140, 'Cloud Run ADK', ['adk runtime service account', 'Vertex AI · MCP Invoker'], '#faf5ff', '#c4b5fd'),
        box(680, 545, 280, 140, 'Cloud Run MCP / Job', ['mcp runtime · store sync job', 'Scheduler 실행 전용 권한'], '#ecfdf5', '#86efac'),
        box(1035, 195, 270, 120, 'Firestore · Storage', ['쿠폰·사용 이력', '공식 문서 RAG'], '#f8faff'),
        box(1035, 345, 270, 120, 'Vertex Pipeline Bucket', ['pipeline runner service account', '검증 artifact 보관'], '#f8faff'),
        box(1035, 495, 270, 120, 'Secret Manager', ['Data.go API · MCP Token', '접근 권한만 IaC 관리'], '#f8faff'),
        box(1380, 195, 265, 130, 'IAM 최소 권한', ['API · ADK · MCP · Pipeline', '서비스 계정 분리'], '#fcfaff', '#eadcff'),
        box(1380, 360, 265, 130, 'API 활성화 · Budget', ['필요한 GCP API 선언', '비용 경보 기준'], '#fcfaff', '#eadcff'),
        box(1380, 525, 265, 130, 'Secret 경계', ['실제 비밀값은 Terraform', 'state · 저장소에 기록 금지'], '#fcfaff', '#eadcff'),
        arrow(285, 455, 365, 455), arrow(610, 270, 680, 270), arrow(610, 440, 680, 440), arrow(610, 615, 680, 615),
        arrow(960, 270, 1035, 255), arrow(960, 440, 1035, 405), arrow(960, 615, 1035, 555),
        arrow(1305, 255, 1380, 255), arrow(1305, 405, 1380, 425), arrow(1305, 555, 1380, 585)
    ]
    (OUT / 'couponcok-infrastructure-architecture.svg').write_text(close(p), encoding='utf-8')

def deployment():
    p = frame('CouponKok · Container CI/CD 및 승인형 배포 아키텍처', '검증된 컨테이너만 후보 리비전으로 배포하고, 사람 승인 후 트래픽을 전환', ['1 Source', '2 CI Quality Gate', '3 Build · Registry', '4 CD · Runtime', '5 Observe · Rollback'])
    p += [
        box(75, 195, 210, 530, 'Developer', ['main branch push', '기능 단위 commit', 'Prompt manifest 변경'], '#f7faff'),
        box(365, 195, 250, 150, 'GitHub Actions', ['lint · API 계약 테스트', 'Golden Test 60/60', 'ADK evalset schema'], '#eef4ff', '#9db6ff'),
        box(365, 385, 250, 150, 'Prompt / RAG Gate', ['SHA-256 · 버전 일치', '문서 계약 · 권리 확인', '실패 시 중단'], '#faf5ff', '#c4b5fd'),
        box(365, 575, 250, 105, 'Human Review', ['릴리스·트래픽 승인'], '#fff8e8', '#fbbf24'),
        box(685, 195, 270, 150, 'Cloud Build', ['Docker image build', '테스트 통과 소스만 빌드', '이미지 digest 생성'], '#eef4ff', '#9db6ff'),
        box(685, 400, 270, 130, 'Artifact Registry', ['API · ADK · MCP 이미지', '불변 digest · 버전 보관'], '#f8faff'),
        box(1025, 195, 285, 150, 'Candidate Cloud Run', ['API · ADK · MCP 컨테이너', '서비스 계정 · Secret 주입', '헬스 체크'], '#ecfdf5', '#86efac'),
        box(1025, 400, 285, 130, 'Traffic Promotion', ['사람 승인 후 revision 전환', '자동 승인 경로 없음'], '#fff8e8', '#fbbf24'),
        box(1025, 575, 285, 105, 'Rollback', ['이전 revision으로 복구', '검증된 RAG index 유지'], '#fef2f2', '#fca5a5'),
        box(1380, 195, 265, 150, 'Cloud Logging · Trace', ['요청 지연 · 오류 · Tool trace', '속성 키 살균'], '#fcfaff', '#eadcff'),
        box(1380, 400, 265, 130, 'Release Evaluation', ['Staging Holdout · Trajectory', '운영 전 수동 live 평가'], '#fcfaff', '#eadcff'),
        box(1380, 575, 265, 105, 'Alert · Cost', ['오류율 · quota · 비용 경보'], '#fcfaff', '#eadcff'),
        arrow(285, 270, 365, 270), arrow(490, 345, 490, 385), arrow(615, 270, 685, 270), arrow(820, 345, 820, 400), arrow(955, 465, 1025, 270), arrow(1168, 345, 1168, 400), arrow(1168, 530, 1168, 575), arrow(1310, 270, 1380, 270), arrow(1310, 465, 1380, 465), arrow(1310, 625, 1380, 625)
    ]
    (OUT / 'couponcok-deployment-architecture.svg').write_text(close(p), encoding='utf-8')

infrastructure()
deployment()
