---
marp: true
theme: default
paginate: true
header: 'ADK A2A + GCP エージェント統制'
---

<!--
このリポジトリを理解するための資料。読んで分かることを目的にしていて、
発表用の台本ではない。1枚ごとに1つの論点を、その場で完結するように
書いてある。

  marp docs/slides.md -o slides.html
  marp docs/slides.md --pdf

素の Markdown としてもそのまま読める。

方針: `make` ターゲットは全て素のコマンドに展開している。
`agents-cli` のように内部を展開できないものは、実際に何を実行しているかを
日本語で説明している。
-->

# ADK の A2A と GCP のエージェント統制

**経費精算チェックを題材にしたサンプルの読み方**

Agent Identity / Agent Registry / Agent Gateway / Model Armor
ツールチェーンは agents-cli + uv

---

## この資料の読み方

- **前半（Part 1）** ローカルで A2A を動かす。自分のマシンだけで完結する
- **後半（Part 2）** 同じコードに GCP の統制レイヤを被せる。組織付きプロジェクトが要る

各スライドは独立して読めるようにしてあり、コマンドは `make` を使わずに
実行できる形まで展開してある。

**先に押さえるべき考え方が3つある**（6〜8枚目）。
そこだけ理解すれば、残りの罠はほぼ全部その帰結として説明がつく。

---

## このサンプルが答える問い

**Q1. 「エージェント同士が喋る」とは具体的に何をしているのか**
→ カードを取得し、カードに書かれた URL へ JSONRPC を送っている。それだけ

**Q2. そのエージェントは誰の権限で動いているのか**
→ Agent Identity（SPIFFE ID）。サービスアカウントではない

**Q3. そのエージェントはどこへ出て行けるのか**
→ Agent Gateway が制御する。Registry 未登録の先は既定でブロック

**Q4. やり取りされる内容は検査されているのか**
→ Model Armor がプロンプトインジェクションと悪意ある URI を見る

**Q5. 別のランタイムに載ったエージェントとはどう繋ぐのか**
→ A2A は同じ。変わるのは統制の当て方（Identity / Registry / IAM）だけ

---

## 題材：経費精算チェック

4体のエージェントで役割を分ける

| エージェント | 責務 | 判定 | デプロイ先 |
|---|---|---|---|
| **receipt-agent** | 領収書 ID から金額・通貨・日付・店舗・カテゴリを取り出す | しない | Agent Runtime |
| **fx-agent** | 外貨建ての金額を社外由来のレートで円換算する | しない | **Cloud Run** |
| **policy-agent** | 金額（円）とカテゴリを経費規程と照合する | する | Agent Runtime |
| **expense-orchestrator** | 上の3体に委譲し、結果が揃ってから報告する | 集約のみ | Agent Runtime |

> **なぜ分けるか。** 機能の都合ではなく、あとで**権限を別々に絞るため**。
> receipt だけが領収書バケットを読めればよく、policy には要らない。
> 1体の万能エージェントだと、この分離が原理的にできない。
> → Part 2 の IAM でこの設計が効いてくる

---

## なぜ fx-agent だけ別ランタイムなのか

**社内の事実（receipt）と社外由来の事実（fx）は、出どころが違う。**
実運用でも、為替のような全社共通データは経費精算チームの持ち物ではなく、
別のチームが別の基盤で動かしていることの方が多い。

このサンプルではそれを `deployment_target: cloud_run` で表現している。

```
海外出張の領収書  R-1004: 320 USD / 宿泊
        ↓ receipt-agent（社内の事実）
    320 USD である
        ↓ fx-agent（社外由来の事実 / 別ランタイム）
    48,736 円である（1 USD = 152.3 円）
        ↓ policy-agent（判定）
    宿泊の上限 15,000 円を超過 → VIOLATION
```

> **A2A の側には何も出てこない。** カードのパスも呼び方も他の2体と同じ。
> 差が出るのは Part 2 — Agent Identity が付かず、Registry へは手動登録し、
> 呼ばれる側は Cloud Run の IAM で守る

---

## 中核の考え方① 1プロジェクト = 1エージェント

agents-cli の単位はプロジェクト。4体なので**リポジトリに4プロジェクト**が並ぶ。

```
receipt-agent/            agents-cli プロジェクト（公開側 / agent_runtime）
policy-agent/             agents-cli プロジェクト（公開側 / agent_runtime）
fx-agent/                 agents-cli プロジェクト（公開側 / cloud_run）
expense-orchestrator/     agents-cli プロジェクト（呼ぶ側 / agent_runtime）
Makefile                  4つを束ねる薄いラッパ
```

デプロイ先は各プロジェクトの `agents-cli-manifest.yaml` に書いてある。
**1プロジェクト = 1エージェント = 1デプロイ先**という単位で揃っている。

各プロジェクトは独立していて、`cd` すれば `agents-cli` がそのまま使える:

```bash
cd receipt-agent
agents-cli playground        # このエージェント単体の UI
agents-cli run "R-1001 は?"  # 単発実行
```

> ルートの Makefile は「4つに同じ操作を流す」だけのもの。
> agents-cli を隠しているわけではない

---

## 中核の考え方② 呼ぶ側と公開側は非対称

```
expense-orchestrator （呼ぶ側 / RemoteA2aAgent x3）  ← playground が読み込む。サーブしない
   ├── receipt-agent  （公開側 :18001）             ← uvicorn でサーブする
   ├── policy-agent   （公開側 :18002）             ← uvicorn でサーブする
   └── fx-agent       （公開側 :18003）             ← uvicorn でサーブする
```

| | 公開側 | 呼ぶ側 |
|---|---|---|
| 起動 | `uvicorn app.fast_api_app:app` | `agents-cli playground` |
| ポート | 持つ | **持たない** |
| A2A | 生やす（`/a2a/app`） | 消費する（`RemoteA2aAgent`） |

> **オーケストレータは起動してもポートを開かない。**
> 「4体あるからサーバも4つ」と思うと、最初はここで戸惑いやすい

---

## 中核の考え方③ 呼び出しは2段構え

```
RemoteA2aAgent                     receipt-agent (uvicorn :18001)
      │                                       │
      ├── 1. GET /a2a/app/.well-known/agent-card.json ─→│
      │←──────────── card.supportedInterfaces[].url ────┤
      │                                       │
      └── 2. A2A JSONRPC（カード記載の URL 宛）─────────→│
```

**カードを取る → カードに書かれた URL へ送る**

> このサンプルで踏む罠は、ほぼ全部この2段のどちらかで起きる。
> - 1段目が失敗 → カードのパス違い（罠②）/ `--url` の渡し方（罠③）
> - 2段目が失敗 → カードの URL と実際の listen 先が食い違っている（罠①）

---

## ツールチェーン: uv + agents-cli

**`python -m venv` も `pip install` も使わない。**

| やりたいこと | コマンド | 実体 |
|---|---|---|
| agents-cli を入れる | `uv tool install google-agents-cli` | — |
| 依存を入れる | `agents-cli install` | `uv sync` |
| Python を実行する | `uv run python ...` | プロジェクトの `.venv` を自動選択 |
| UI を出す | `agents-cli playground` | `uv run adk web . --host --port` |
| 単発で実行する | `agents-cli run "..."` | ローカル or `--url` でリモート |
| デプロイ | `agents-cli deploy` | Agent Runtime へ（SDK 経由） |

> `uv sync` が各プロジェクトの `.venv` を作り、`uv run` がそれを自動で選ぶ。
> activate は要らない

---

## ポートと変数の対応

| ポート | 用途 | listen 側 | カード側 |
|---|---|---|---|
| 18000 | playground（UI） | `WEB_PORT` | — |
| 18001 | receipt-agent | `RECEIPT_PORT` | `APP_URL` |
| 18002 | policy-agent | `POLICY_PORT` | `APP_URL` |
| 18003 | fx-agent | `FX_PORT` | `APP_URL` |

**変数が2系統ある**のがこのリポジトリの分かりにくい点。

- 左 = uvicorn が実際に bind するポート
- 右 = カードに広告する URL（`APP_URL=http://localhost:18001`）

Makefile の `serve_agent` マクロが両方を同時に渡して同期させている。食い違うと罠①

---

## 検証環境

```
agents-cli 1.4.2 / google-adk 2.x / a2a-sdk 1.x / Python 3.11 / uv
```

listen するのは 18000 / 18001 / 18002 / 18003 の4つだけ。
既定を 18000 番台にしているのは、他のアプリと衝突しにくくするため。

a2a-sdk はバージョン間の差が大きいが、**A2A のコードは scaffold が生成する**ので
自分でバージョン差を吸収する必要はない（そのために手書きしない）。

---

# Part 1 — ローカルで A2A を動かす

`install` → `run` → `card` → `smoke` → `chat`

---

## プロジェクトはどう作られたか

4つとも `agents-cli scaffold create` で生成した:

```bash
agents-cli scaffold create receipt-agent \
  --agent adk --deployment-target agent_runtime \
  --prototype --region us-central1 --agent-guidance-filename CLAUDE.md

agents-cli scaffold create policy-agent  （同じ）

agents-cli scaffold create fx-agent \
  --agent adk --deployment-target cloud_run \      # ← ここだけ違う
  --region us-central1 --agent-guidance-filename CLAUDE.md

agents-cli scaffold create expense-orchestrator \
  --agent adk --deployment-target agent_runtime \
  --prototype --region us-central1 --agent-guidance-filename CLAUDE.md \
  --agent-gateway          # ← オーケストレータだけ
```

> `--agent-gateway` は Dockerfile にゲートウェイのルート CA を信頼させるフラグ。
> **これ無しに `deploy --agent-gateway-egress` はできない**（罠⑤）。
> 生成時に何を指定したかは各プロジェクトの `agents-cli-manifest.yaml` に残る

---

## 生成される構造と、触ってよいファイル

```
receipt-agent/
├── app/
│   ├── agent.py            ← ★ 触るのはここだけ
│   ├── fast_api_app.py     ← 生成物。FastAPI + A2A ルート
│   └── app_utils/a2a.py    ← 生成物。attach_a2a_routes()
├── agents-cli-manifest.yaml ← 生成物。CLI が読む
├── pyproject.toml / uv.lock ← 依存
├── Dockerfile               ← 生成物
├── deployment/terraform/    ← 生成物
├── tests/                   ← unit / integration / eval
└── .env                     ← プロジェクトID・認証（gitignore 済み）
```

> **A2A のコードは絶対に手書きしない。** import パスも `AgentCard` のスキーマも
> バージョン間で変わる。scaffold に任せる

---

## 依存を入れる

`make install` の実体:

```bash
cd receipt-agent        && agents-cli install
cd policy-agent         && agents-cli install
cd fx-agent             && agents-cli install
cd expense-orchestrator && agents-cli install
```

`agents-cli install` の実体:

```bash
uv sync
```

> `uv sync` は `pyproject.toml` と `uv.lock` から各プロジェクトの `.venv` を作る。
> `uv run` がそれを自動で選ぶので activate は不要

---

## エージェントは対話で作る

scaffold 直後の `app/agent.py` は**天気ツールのテンプレート**（`get_weather` /
`get_current_time`）。ここから各エージェントへの作り込みは、
**コーディングエージェントへのプロンプト**で行う:

```bash
uvx google-agents-cli setup   # ADK スキル一式を入れる（初回のみ）
cd receipt-agent
claude                        # プロジェクトの CLAUDE.md が文脈として読み込まれる
```

プロンプトの型（4体とも共通）:

- **役割の境界を伝える** — receipt = 社内の事実だけ / fx = 社外由来の事実だけ /
  policy = 判定だけ / orchestrator = 委譲と集約だけ
- **生成物に触らせない** — `fast_api_app.py` / `app_utils/` / manifest は対象外と明言
- **確認までさせる** — 終わったら `agents-cli run "..."` で動作確認

> 「どのファイルをどう書き換えるか」より境界を伝えるほうが崩れない。
> この境界はそのまま Part 2 の権限分離の単位になる

---

## receipt-agent を作るプロンプト

```text
テンプレートの get_weather / get_current_time を置き換えて、
領収書の読み取りエージェントにして。

- 役割: 領収書に関する「事実」だけを返す。判定はしない
- ツール1 extract_receipt(receipt_id): R-XXXX 形式の ID から
  金額・通貨・日付・店舗・カテゴリを返す。本来は OCR + BigQuery だが、
  ローカルで完結するようモックデータ5件（R-1001〜R-1005）で代替。
  R-1004 / R-1005 は海外出張ぶんで、通貨が USD / EUR
- ツール2 list_receipts(): 登録済み ID の一覧を返す
- Agent の name は receipt_agent。instruction にも
  「事実だけを返す。判定はしない」と書く
- モデルは環境変数 ADK_MODEL で差し替えられるようにする（既定は今のまま）
- App(name="app") と生成物（fast_api_app.py / app_utils）は触らない

終わったら agents-cli run "R-1001 は?" で引けることを確認して。
```

> 結果が次のスライドの `app/agent.py`。モデルを指示なく変えさせないこと
> （変えてよいのは明示的に頼んだところだけ）

---

## 公開側のコード: receipt-agent

`receipt-agent/app/agent.py`

```python
MODEL = os.environ.get("ADK_MODEL", "gemini-3.7-flash")

def extract_receipt(receipt_id: str) -> dict:
    """領収書IDから金額・通貨・日付・店舗・カテゴリを取り出す。

    Args:
        receipt_id: R-XXXX 形式の領収書ID
    """
    rec = _EXPENSE_DB.get(receipt_id)   # 本来は OCR + BigQuery。ここはモック
    ...

root_agent = Agent(
    name="receipt_agent",
    model=Gemini(model=MODEL, retry_options=types.HttpRetryOptions(attempts=3)),
    instruction="... 事実だけを返す。判定はしない。",
    tools=[extract_receipt, list_receipts],
)

app = App(root_agent=root_agent, name="app")   # ← name はディレクトリ名と一致させる規約
```

> 関数の docstring が**そのままツールの説明として LLM に渡る**。Args も含めて書く

---

## policy-agent を作るプロンプト

```text
テンプレートを経費規程チェックのエージェントにして。

- ツール check_policy(amount, category): 上限表
  （会食 10000 / 消耗品 5000 / 宿泊 15000 / 交通費 30000）と照合し、
  OK / VIOLATION / REVIEW（未知カテゴリ）のいずれかを返す
- 判定ロジックは check_policy の中に閉じる。LLM に判定させない。
  LLM の仕事は「ツールを呼ぶこと」と「結果を返すこと」だけ
- Agent の name は policy_agent
- App(name="app") と生成物は触らない

終わったら agents-cli run "宿泊で 45000 円は?" で
VIOLATION が返ることを確認して。
```

> 「LLM に判定させない」を書き忘れると、上限表を instruction に書いて
> モデルに比較させる実装になりやすい。境界は明文化する

---

## 公開側のコード: policy-agent

`policy-agent/app/agent.py`

```python
_LIMITS = {"会食": 10000, "消耗品": 5000, "宿泊": 15000, "交通費": 30000}

def check_policy(amount: int, category: str) -> dict:
    limit = _LIMITS.get(category)
    if limit is None:
        return {"verdict": "REVIEW", "reason": f"未知のカテゴリ: {category}"}
    if amount > limit:
        return {"verdict": "VIOLATION",
                "reason": f"{category} の上限 {limit} 円を超過（{amount} 円）", "limit": limit}
    return {"verdict": "OK", "limit": limit}
```

> **判定を LLM に任せず関数に閉じている。** 規程は決定的に評価されるべきで、
> 金額の大小比較を確率的なモデルに委ねる理由が無い。
> LLM が担当するのは「どのツールを呼ぶか」と「結果をどう報告するか」だけ

---

## fx-agent を作るプロンプト

**別ランタイム行きだが、プロンプトの型は他の2体と変わらない。**

```text
テンプレートを外貨の円換算エージェントにして。

- 役割: 換算だけする。規程に適合するかどうかの判定はしない
- ツール1 convert_to_jpy(amount, currency): 通貨コードとレート表から
  円換算した金額・適用レート・基準日を返す。本来は社外の為替 API だが、
  ローカルで完結するようスナップショットで代替（USD / EUR / GBP / KRW）
- ツール2 list_rates(): 換算できる通貨と適用レートを返す
- Agent の name は fx_agent
- App(name="app") と生成物は触らない

終わったら agents-cli run "320 USD は何円?" で引けることを確認して。
```

> **デプロイ先の話はプロンプトに出てこない。** `deployment_target` は
> scaffold 時に決まっていて、`app/agent.py` の書き方には影響しない

---

## 別ランタイムのコード: fx-agent

`fx-agent/app/agent.py` — **他の公開側と見分けが付かない**

```python
_AS_OF = "2026-08-22"
_RATES = {"USD": 152.30, "EUR": 165.80, "GBP": 193.40, "KRW": 0.111}

def convert_to_jpy(amount: float, currency: str) -> dict:
    code = currency.upper()
    if code == "JPY":
        return {"amount_jpy": round(amount), "currency": "JPY", "rate": 1.0}
    rate = _RATES.get(code)
    if rate is None:
        return {"error": f"レートを持っていない通貨: {currency}"}
    return {"amount_jpy": round(amount * rate), "currency": code,
            "rate": rate, "as_of": _AS_OF, "source": "社外の為替サービス"}

app = App(root_agent=root_agent, name="app")   # ← 他と同じ
```

**Cloud Run 行きであることが現れる場所は、コードの外にしかない:**

| 場所 | 中身 |
|---|---|
| `agents-cli-manifest.yaml` | `deployment_target: cloud_run` |
| `app/fast_api_app.py` | `reasoning_engine_adapter` が無い（Agent Runtime 専用） |
| `pyproject.toml` | `agent-engines` の代わりに `fastapi` / `uvicorn` を直接持つ |

> ローカルで動かしている限り、この3つを見に行かないと違いに気づけない

---

## A2A はどこから来るのか

`app/agent.py` に A2A のコードは一行も無い。生やしているのは生成物のほう:

`app/fast_api_app.py`
```python
from app.agent import app as adk_app
await attach_a2a_routes(
    app, agent=root_agent, runner=runner, task_store=...,
    rpc_path=f"/a2a/{adk_app.name}",      # ← "/a2a/app"
)
```

`app/app_utils/a2a.py`（`attach_a2a_routes` の中）
- `AgentCardBuilder` でカードを動的に生成
- カードを `{rpc_path}/.well-known/agent-card.json` で配る
- JSONRPC を `{rpc_path}` で受ける

> `App(name="app")` が `/a2a/app` の `app` を決めている。
> ディレクトリ名と一致させる規約なので、通常は変えない

---

## 起動する

`make run` の実体（既定ポートを埋めたもの）:

```bash
# 1) ポートが空いているか確認
lsof -nP -iTCP:18001 -sTCP:LISTEN
lsof -nP -iTCP:18002 -sTCP:LISTEN
lsof -nP -iTCP:18003 -sTCP:LISTEN

# 2) 起動（APP_URL と --port を必ずセットで渡す）
mkdir -p .pids .logs
APP_URL=http://localhost:18001 nohup uv run --directory receipt-agent \
  uvicorn app.fast_api_app:app --host localhost --port 18001 \
  > .logs/receipt-agent.log 2>&1 & echo $! > .pids/receipt-agent.pid
APP_URL=http://localhost:18002 nohup uv run --directory policy-agent \
  uvicorn app.fast_api_app:app --host localhost --port 18002 \
  > .logs/policy-agent.log 2>&1 & echo $! > .pids/policy-agent.pid
APP_URL=http://localhost:18003 nohup uv run --directory fx-agent \
  uvicorn app.fast_api_app:app --host localhost --port 18003 \
  > .logs/fx-agent.log 2>&1 & echo $! > .pids/fx-agent.pid
```

> **Cloud Run 行きの fx-agent も、ローカルでは同じ uvicorn の1行。**
> `uv run --directory <proj>` で、そのプロジェクトの `.venv` を使って実行する

---

## 起動の失敗を見逃さない

```bash
# 3) カードが返るまで最大60秒待つ。返らなければログを出して非ゼロ終了
for i in $(seq 1 60); do
  curl -sf localhost:18001/a2a/app/.well-known/agent-card.json >/dev/null &&
  curl -sf localhost:18002/a2a/app/.well-known/agent-card.json >/dev/null &&
  curl -sf localhost:18003/a2a/app/.well-known/agent-card.json >/dev/null && exit 0
  sleep 1
done
echo "ERROR: 60秒以内にエージェントカードが取得できませんでした。ログ:"
tail -n 20 .logs/*.log
exit 1
```

> **待ちループに失敗分岐が無いと、停止したサーバが正常に見える。**
> 成功バナーを無条件に出すと、1つも起動していなくても「起動しました」になる

---

## 罠① `APP_URL` は bind しない

```
make run ──┬─→ uvicorn --port 18001    ← 実際に listen するのはこっち
           └─→ APP_URL=http://localhost:18001  ← カードに載る URL を組むのはこっち
```

`APP_URL` は **カードに広告する URL を組み立てるだけ**で、待ち受けはしない。

**未設定だと `http://0.0.0.0:8000` が広告される**（コード上のフォールバック）:

```json
"supportedInterfaces": [{ "url": "http://0.0.0.0:8000/a2a/app", ... }]
```

- 起動は成功する（uvicorn は指定ポートで正常に上がる）
- エラーは呼び出し側で「接続できない」として出る
- したがって原因に辿り着きにくい

> Makefile の `serve_agent` マクロが `APP_URL` と `--port` を同時に渡している

---

## カードを見る

`make card` の実体:

```bash
curl -s localhost:18001/a2a/app/.well-known/agent-card.json | python3 -m json.tool
curl -s localhost:18002/a2a/app/.well-known/agent-card.json | python3 -m json.tool
curl -s localhost:18003/a2a/app/.well-known/agent-card.json | python3 -m json.tool
```

```json
{
  "name": "receipt_agent",
  "supportedInterfaces": [
    { "url": "http://localhost:18001/a2a/app", "protocolBinding": "JSONRPC", "protocolVersion": "1.0" },
    { "url": "http://localhost:18001/a2a/app", "protocolBinding": "JSONRPC", "protocolVersion": "0.3" }
  ],
  "skills": [ "model", "extract_receipt", "list_receipts" ]
}
```

> 0.3 のインターフェースも併記されるのは、v0.3 クライアント（Gemini Enterprise の
> 登録バリデータ等）から見えるようにするため。
> **Cloud Run 行きの fx-agent のカードも形は全く同じ** — カードだけ見ても
> どのランタイムに載る予定なのかは分からない

---

## 罠② カードのパス

| パス | 結果 |
|---|---|
| `/a2a/app/.well-known/agent-card.json` | **200** |
| `/.well-known/agent-card.json`（ルート直下） | **404** |

`/a2a/` の後ろは `app/agent.py` の `App(name=...)`。

> 素の ADK（`to_a2a()`）だとルート直下に出るので、そちらの資料を参照していると間違えやすい。
> scaffold 構成では必ず `/a2a/{App.name}` の下

---

## A2A で1往復させる

`make smoke` の実体:

```bash
cd receipt-agent && agents-cli run "R-1004 の領収書の内容を教えて" \
  --url http://localhost:18001 --mode a2a

cd fx-agent && agents-cli run "320 USD は何円ですか" \
  --url http://localhost:18003 --mode a2a

cd policy-agent && agents-cli run "宿泊で 48736 円は規程に適合しますか" \
  --url http://localhost:18002 --mode a2a
```

出力:

```
[agent]: 領収書 R-1004 の内容は以下の通りです。
- 領収書ID: R-1004 / 日付: 2026-08-22 / 店舗: Hotel Bayview
- カテゴリ: 宿泊 / 金額: 320 USD

[agent]: 換算後金額 48,736 円 / 適用レート 1 USD = 152.3 円

[agent]: 宿泊の上限15,000円を超過しているため、規程違反（VIOLATION）となります。
```

> 3体を1体ずつ叩いているだけで、繋いでいるのは人間。
> 繋ぐのはオーケストレータの仕事（このあとの `make chat`）

> **これは LLM を呼ぶ。** 配線の確認だけなら `make card` で足りる

---

## 罠③ `--url` にはベース URL を渡す

```bash
agents-cli run "..." --url http://localhost:18001 --mode a2a       # ✅
agents-cli run "..." --url http://localhost:18001/a2a/app --mode a2a  # ❌ 404
```

CLI 側が `/a2a/{app_name}` を**自動で足す**:

```python
a2a_base = f"{service_url}/a2a/{app_name}"
card_url = f"{a2a_base}{AGENT_CARD_WELL_KNOWN_PATH}"
```

> カードのパス（罠②）を知っているほど間違えやすい。
> `curl` にはフルパス、`agents-cli run --url` にはベース URL

---

## expense-orchestrator を作るプロンプト

```text
テンプレートを、receipt_agent / fx_agent / policy_agent を A2A で呼ぶ
オーケストレータにして。

- RemoteA2aAgent を3つ作り、AgentTool で包んで tools に渡す。カードは
  http://localhost:18001 / :18002 / :18003 の
  /a2a/app/.well-known/agent-card.json
  （RECEIPT_AGENT_URL / POLICY_AGENT_URL / FX_AGENT_URL で上書き可）
- use_legacy=False を明示する（既定 True のままだと旧経路で動く）
- USE_AGENT_REGISTRY=1 のときは Agent Registry から名前で解決する
  分岐も用意する（agents/receipt-agent / agents/policy-agent / agents/fx-agent）
- instruction: まず receipt_agent、通貨が JPY 以外なら fx_agent で円換算、
  そのうえで policy_agent。結果が揃ってから、違反があれば理由つきで報告する
- 自前のツールは持たせない。事実も判定も持たない

A2A の接続コード自体は書かないこと（RemoteA2aAgent を使うだけ）。
```

> **`sub_agents` ではなく `AgentTool`** と明示するのが肝。
> 「自前のツールを持たせない」が無いと、オーケストレータに事実や判定が
> 入り込んで境界が崩れる

---

## 呼ぶ側: expense-orchestrator/app/agent.py

```python
A2A_RPC_PATH = "/a2a/app"
RECEIPT_URL = os.environ.get("RECEIPT_AGENT_URL", "http://localhost:18001")
FX_URL      = os.environ.get("FX_AGENT_URL",      "http://localhost:18003")

def _card(base_url: str) -> str:
    return f"{base_url}{A2A_RPC_PATH}{AGENT_CARD_WELL_KNOWN_PATH}"

RemoteA2aAgent(
    name="receipt_agent",
    description="領収書の読み取りと経費データとの突き合わせを担当するリモートエージェント",
    agent_card=_card(RECEIPT_URL),
    use_legacy=False,          # ← 罠④
)

# リモート3体はツールとして持つ（罠⑥）
remote_tools = [AgentTool(agent=a) for a in _remote_agents()]

root_agent = Agent(name="expense_orchestrator", model=..., tools=remote_tools,
    instruction="まず receipt_agent。通貨が JPY 以外なら fx_agent で円換算し、"
                "そのうえで policy_agent。結果が揃ってから違反を理由つきで報告する。")
```

> **`fx_agent` だけ別ランタイム行きだが、書き方に差は無い。**
> `description` は LLM が「どれに投げるか」を決める材料になる

---

## 罠④ `use_legacy` の既定は `True`

```python
RemoteA2aAgent(..., use_legacy=False)
```

新しい A2A 統合を使うには **明示的に `False`** を渡す必要がある。

明示しないと**静かに旧経路で動く**。カードの解釈やエラーの出方が変わるため、
「サンプル通りに書いたのに挙動が違う」という形で現れる。

---

## 罠⑥ リモートを `sub_agents` に置くと1体目で止まる

```python
root_agent = Agent(..., sub_agents=[receipt, fx, policy])   # ❌ 1体目で止まる
root_agent = Agent(..., tools=[AgentTool(agent=a) for a in ...])  # ✅
```

`sub_agents` に置かれたエージェントは `transfer_to_agent` の**転送先**になる。
制御ごと相手に渡り、渡した先から戻ってこないので、1ターンのうちに
receipt → fx → policy と辿れない。

ADK は `mode='single_turn'` のサブエージェントをツールとして扱ってくれるが、
**`RemoteA2aAgent` は `mode` フィールドを持たない**（`LlmAgent` だけが持つ）ので
その道は使えない。`AgentTool` で包む。

> 症状は「エラーにならず、receipt_agent が答えて会話が終わる」。
> 落ちないぶん気づきにくい

---

## 対話する

`make chat` の実体:

```bash
lsof -nP -iTCP:18000 -sTCP:LISTEN      # 事前確認
cd expense-orchestrator && agents-cli playground --port 18000
```

`agents-cli playground` の実体:

```bash
uv run adk web . --host localhost --port 18000 --allow_origins '*'
```

> **`make chat` と `make run` は独立している。** playground はオーケストレータを
> 読み込むだけで、receipt/policy/fx は起動しない。先に `make run`

---

## 実行時に何が起きるか

入力: `R-1001 と R-1003 の経費をチェックして`（**円建てだけ**）

```
expense_orchestrator
  ├─→ receipt_agent  extract_receipt("R-1001") → 12800 JPY / 会食
  │                  extract_receipt("R-1003") → 45000 JPY / 宿泊
  ├─→ policy_agent   check_policy(12800, "会食") → OK
  │                  check_policy(45000, "宿泊") → VIOLATION（上限 15000）
  └─→ 両方揃ってから報告
```

結果: **R-1003（宿泊 45,000 円 > 上限 15,000 円）だけが違反**

> 円建てなので fx_agent は呼ばれない。呼ぶかどうかは
> `currency` を見た LLM の判断で決まる

---

## 別ランタイムを挟むとどうなるか

入力: `R-1004 の経費をチェックして`（**外貨**）

```
expense_orchestrator
  ├─→ receipt_agent  extract_receipt("R-1004") → 320.0 USD / 宿泊
  │                    ↑ Agent Runtime 行き
  ├─→ fx_agent       convert_to_jpy(320.0, "USD") → 48736 JPY（1 USD = 152.3）
  │                    ↑ Cloud Run 行き ← ★ ここだけランタイムが違う
  ├─→ policy_agent   check_policy(48736, "宿泊") → VIOLATION（上限 15000）
  │                    ↑ Agent Runtime 行き
  └─→ 揃ってから報告（レートと換算後の金額も添える）
```

> **ホップが1つ増えただけで、通信の中身は何も変わっていない。**
> playground の trace ビューでも3つとも同じ A2A 呼び出しとして並ぶ

---

## 停止する

`make stop` の実体:

```bash
for p in .pids/*.pid; do
  kill -TERM "$(cat "$p")" 2>/dev/null || true
  rm -f "$p"
done
pkill -f "[a]pp\.fast_api_app" 2>/dev/null || true
```

> **`[a]pp` と書いてあるのは誤植ではない。**
> `pkill -f "app.fast_api_app"` と書くと、pkill 自身のコマンドラインが
> パターンに一致して **make ごと終了してしまう**。
> `[a]pp` は `app` にマッチするが、文字列 `[a]pp` 自身にはマッチしない

---

## agents-cli の各コマンドが実際に何をするか

<!-- 内部を素のコマンドに展開できないものは、実行内容を説明 -->

| コマンド | 実体 |
|---|---|
| `agents-cli install` | `uv sync` |
| `agents-cli playground` | `uv run adk web . --host --port --allow_origins '*'` |
| `agents-cli run "..."` | ローカルサーバを一時起動して1回だけ送る |
| `agents-cli run --url --mode a2a` | `{url}/a2a/{app}` にカード取得 → JSONRPC |
| `agents-cli lint` | ruff + ty + codespell |
| `agents-cli deploy` | manifest の `deployment_target` を見て分岐（`agent_runtime` / `cloud_run` / `gke`） |
| `agents-cli publish` | Gemini Enterprise への登録のみ |

> `agents-cli <command> --help` の末尾に `Source:` 行があり、
> 実装ファイルの絶対パスが出る。迷ったらそれを読む

---

# Part 2 — GCP の統制レイヤ

同じ `app/agent.py` をクラウドに載せ、統制を被せる

---

## 統制の4レイヤ

| レイヤ | プロダクト | 答える問い |
|---|---|---|
| 身分 | **Agent Identity** | このエージェントは**誰**か |
| 名簿 | **Agent Registry** | どのエージェントが**存在**するか |
| 出口 | **Agent Gateway** | **どこへ出て行って**よいか |
| 検査 | **Model Armor** | 出入りする**内容**は安全か |

適用順序: `gcp-apis` → `gcp-deploy` → `gcp-iam` → `gcp-gateway` → `gcp-model-armor`

> **順序に意味がある。** 身分が無いと IAM が付けられず、
> デプロイしないと身分が発行されない

---

## 前提: 組織付きプロジェクトが必須

Agent Identity は SPIFFE ID として発行される:

```
principal://agents.global.org-${ORG_ID}.system.id.goog
           /resources/aiplatform/projects/${PROJECT_NUMBER}
           /locations/${LOCATION}/reasoningEngines/${AGENT_ENGINE_ID}
```

- **trust domain に組織 ID が埋まる** → 組織なしプロジェクトでは成立しない
- **長期鍵が存在しない** → 持ち出せる秘密が無い

> 従来のサービスアカウントとの最大の違い。JSON キーを配布する運用が
> 構造的にできない。漏洩する鍵が無いので、鍵のローテーションという
> 概念自体が消える

---

## API を有効化

`make gcp-apis` → `./scripts/gcp_enable_apis.sh` の実体:

```bash
gcloud services enable \
  aiplatform.googleapis.com \
  agentregistry.googleapis.com \
  agentidentitycredentials.googleapis.com \
  networkservices.googleapis.com \
  networksecurity.googleapis.com \
  modelarmor.googleapis.com \
  compute.googleapis.com iam.googleapis.com \
  logging.googleapis.com monitoring.googleapis.com \
  --project "$GOOGLE_CLOUD_PROJECT"
```

> 4レイヤに対応する API が並んでいる。`agentidentitycredentials` が身分、
> `agentregistry` が名簿、`networkservices`/`networksecurity` が出口、
> `modelarmor` が検査

---

## 環境変数は2系統ある

| ファイル | 用途 |
|---|---|
| ルートの `.env` | **GCP 統制スクリプト用**（`make gcp-*` / `scripts/gcp_*.sh`） |
| 各プロジェクトの `.env` | **エージェント自身の設定**（プロジェクトID / 認証 / モデル） |

```bash
cp .env.example .env
set -a; source .env; set +a      # export しながら読み込む
```

```bash
GOOGLE_CLOUD_PROJECT=your-project-id
GOOGLE_CLOUD_LOCATION=us-central1
ORG_ID=123456789012
STAGING_BUCKET=your-staging-bucket
# AGENT_GATEWAY=projects/.../locations/us-central1/agentGateways/expense-gw
```

> 各プロジェクトの `.env` は scaffold が生成し、実プロジェクトIDが入る。
> どちらも `.gitignore` 済み

---

## デプロイする

`make gcp-deploy` の実体:

```bash
cd receipt-agent        && agents-cli deploy --agent-identity
cd policy-agent         && agents-cli deploy --agent-identity
cd expense-orchestrator && agents-cli deploy --agent-identity \
                             --agent-gateway-egress "$AGENT_GATEWAY"
cd fx-agent             && agents-cli deploy          # ← --agent-identity を付けない
```

- `--agent-identity` → `identity_type=AGENT_IDENTITY` で SPIFFE ID が発行される
- `--agent-gateway-egress` → egress をゲートウェイに固定（**オーケストレータのみ**）
- **fx-agent には付けない** → `--agent-identity` は Agent Runtime 専用の分岐でしか
  読まれず、Cloud Run のデプロイでは無視される

> 外部に出ていくのがオーケストレータだから、通すのもそれだけ。
> receipt/policy/fx は内側で完結する

---

## 同じ `deploy` が2つのランタイムに出る

**コマンドは同じ。デプロイ先は manifest が決める。**

```bash
agents-cli deploy      # 引数はどのプロジェクトでも同じ
```

```
agents-cli-manifest.yaml の deployment_target
  ├── agent_runtime → Agent Runtime へ（SDK 経由）
  ├── cloud_run     → gcloud run deploy --source . --no-allow-unauthenticated
  └── gke           → terraform + docker build + kubectl apply
```

Cloud Run 側で自動的に入るもの:

| 入るもの | 値 |
|---|---|
| `APP_URL` | `https://{service}-{project_number}.{region}.run.app`（カードの URL になる） |
| 認証 | `--no-allow-unauthenticated`（呼ぶには ID トークンが要る） |

> **`APP_URL` をローカルと同じ仕組みで埋めてくれる**（罠①の裏返し）。
> 手で渡す必要はないが、何が入ったかは deploy の出力で確認する

---

## 罠⑤ `--agent-gateway` は scaffold 時のフラグ

**2つは別物。名前が似ているだけ。**

| フラグ | いつ | 何をする |
|---|---|---|
| `scaffold create --agent-gateway` | プロジェクト作成時 | Dockerfile にゲートウェイのルート CA を信頼させる |
| `deploy --agent-gateway-egress` | デプロイ時 | egress をそのゲートウェイに向ける |

**前者なしに後者はできない。**
このリポジトリでは expense-orchestrator だけ `--agent-gateway` 付きで作ってある
（`agents-cli-manifest.yaml` の `agent_gateway: True` で確認できる）。

---

## IAM を付ける

`make gcp-iam` → `AGENT_ENGINE_ID=xxxx ./scripts/gcp_grant_iam.sh` の実体:

```bash
PROJECT_NUMBER=$(gcloud projects describe "$GOOGLE_CLOUD_PROJECT" \
                   --format='value(projectNumber)')

AGENT_PRINCIPAL="principal://agents.global.org-${ORG_ID}.system.id.goog\
/resources/aiplatform/projects/${PROJECT_NUMBER}\
/locations/${GOOGLE_CLOUD_LOCATION}/reasoningEngines/${AGENT_ENGINE_ID}"

# 共通の下地（推論・セッション・メモリ）
gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
  --member="$AGENT_PRINCIPAL" --role="roles/aiplatform.expressUser" --quiet
```

> **`--member` が `serviceAccount:` ではなく `principal://`。**
> SA を作ってエージェントに紐付けるのではなく、
> エージェントそのものに直接ロールを付けている。
> **このスクリプトの対象は Agent Runtime の3体だけ** — fx-agent には
> そもそも `principal://` が無い

---

## データアクセスは個体ごとに狭く

```bash
# 領収書バケット — receipt-agent にだけ必要
if [[ -n "${RECEIPTS_BUCKET:-}" ]]; then
  gcloud storage buckets add-iam-policy-binding "gs://${RECEIPTS_BUCKET}" \
    --member="$AGENT_PRINCIPAL" --role="roles/storage.objectViewer" --quiet
fi

# ゲートウェイ通行許可（egress）
gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
  --member="$AGENT_PRINCIPAL" --role="roles/iap.egressor" --quiet
```

> **役割を分けたから、権限を分けられる。**
> 題材のスライドで「機能の都合ではなく権限を絞るために分ける」と書いたのは
> ここのこと。policy-agent に領収書バケットの読み取りは要らない

---

## 別ランタイムの身分はどうなるか

**fx-agent には Agent Identity が発行されない。** Agent Runtime の外だから。

| | Agent Runtime の3体 | Cloud Run の fx-agent |
|---|---|---|
| 実行 ID | Agent Identity（`principal://`） | サービスアカウント |
| 長期鍵 | 存在しない | SA なので従来どおりの世界 |
| Registry | deploy が登録 | 手動登録 |
| 呼ばれる側の保護 | IAM + Gateway ingress | Cloud Run の `run.invoker` |

呼ぶ側（オーケストレータ）に通行許可を出す:

```bash
# オーケストレータの principal:// に、fx-agent を叩く権限を付ける
gcloud run services add-iam-policy-binding fx-agent   --region="$GOOGLE_CLOUD_LOCATION" --project="$GOOGLE_CLOUD_PROJECT"   --member="$AGENT_PRINCIPAL" --role="roles/run.invoker" --quiet
```

> **`principal://` は Cloud Run の IAM でもそのまま使える。**
> 身分の発行元がランタイムでも、権限を受け取る側は普通の IAM リソース。
> `FX_SERVICE_NAME=fx-agent` を付けて `make gcp-iam` を流すとここが実行される

---

## Agent Registry に登録する

`make gcp-registry` → `AGENT_BASE_URL=https://... ./scripts/gcp_register_registry.sh` の実体:

```bash
# 生きているカードを取ってくる（自分で書かない）。
# Cloud Run は --no-allow-unauthenticated なので ID トークンが要る
curl -sf -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "${AGENT_BASE_URL}/a2a/app/.well-known/agent-card.json" > "$CARD"

gcloud agent-registry services create "${SERVICE_NAME:-fx-agent}" \
  --project="$GOOGLE_CLOUD_PROJECT" \
  --location="${GOOGLE_CLOUD_LOCATION:-us-central1}" \
  --display-name="${SERVICE_NAME:-fx-agent}" \
  --agent-spec-type=a2a-agent-card \
  --agent-spec-content=@"$CARD"
```

> **登録が要るのは Agent Runtime の外にいる fx-agent だけ。** 他の3体は
> deploy が名簿に載せてくれる。`agents-cli publish` は使えない
> （publish の対象は Gemini Enterprise のみ）。カード上限 10KB

---

## Registry モード: URL のハードコードを消す

`expense-orchestrator/app/agent.py` は環境変数で解決方法が切り替わる:

```python
def _registry_agents():
    from google.adk.integrations.agent_registry import AgentRegistry
    registry = AgentRegistry(project_id=os.environ["GOOGLE_CLOUD_PROJECT"],
                             location=os.environ.get("AGENT_REGISTRY_LOCATION", "global"))
    return [registry.get_remote_a2a_agent("agents/receipt-agent"),
            registry.get_remote_a2a_agent("agents/policy-agent"),
            registry.get_remote_a2a_agent("agents/fx-agent")]   # ← 手動登録した分

remote_tools = [AgentTool(agent=a) for a in _remote_agents()]
```

| 既定 | `USE_AGENT_REGISTRY=1` |
|---|---|
| URL 直指定（ローカル完結） | **名前だけで解決**（要 GCP） |

> **名前で解決できると、どのランタイムに載っているかが呼ぶ側から消える。**
> `agents/fx-agent` が Cloud Run にいることも、後で移設することも、
> このコードには一切現れない。ただし手動登録を忘れると名前が引けずに落ちる

---

## Agent Gateway を作る

`make gcp-gateway` → `./scripts/gcp_create_gateway.sh` の実体:

```bash
TMP=$(mktemp -d)
for f in agent-gateway-egress iap-authz-extension iap-authz-policy; do
  sed -e "s/PROJECT_ID/${GOOGLE_CLOUD_PROJECT}/g" \
      -e "s/REGION/${GOOGLE_CLOUD_LOCATION}/g" \
      "deploy/${f}.yaml" > "${TMP}/${f}.yaml"
done

gcloud network-services agent-gateways import expense-gw \
  --source="${TMP}/agent-gateway-egress.yaml" --location="$LOCATION"
gcloud beta service-extensions authz-extensions import expense-gw-authz-ext \
  --source="${TMP}/iap-authz-extension.yaml" --location="$LOCATION"
gcloud network-security authz-policies import expense-gw-authz-policy \
  --source="${TMP}/iap-authz-policy.yaml" --location="$LOCATION"
```

> `deploy/*.yaml` はプレースホルダを持ち、**sed で置換してから import** する

---

## Gateway と Registry は直結している

`deploy/agent-gateway-egress.yaml`

```yaml
name: expense-gw
protocols:
  - MCP
googleManaged:
  governedAccessPath: AGENT_TO_ANYWHERE
registries:
  - //agentregistry.googleapis.com/projects/PROJECT_ID/locations/REGION
  - //agentregistry.googleapis.com/projects/PROJECT_ID/locations/global
```

**Registry 未登録の MCP は既定でブロックされる**

> 名簿に載っていない先には出て行けない、という設計。
> 「まず登録する」を強制する仕組みになっており、統制としてはこれが一番効く

---

## IAP 認可：まず DRY_RUN

`deploy/iap-authz-extension.yaml`

```yaml
name: expense-gw-authz-ext
service: iap.googleapis.com
failOpen: true
timeout: 1s
metadata:
  iamEnforcementMode: "DRY_RUN"     # ← まずログだけ取る
  iapPolicyVersion: "V1"
```

`deploy/iap-authz-policy.yaml` でゲートウェイに結びつける:

```yaml
target:
  resources: ["projects/PROJECT_ID/locations/REGION/agentGateways/expense-gw"]
policyProfile: REQUEST_AUTHZ
action: CUSTOM
```

> `failOpen: true` と `DRY_RUN` の組み合わせで、最初は何も遮断しない

---

## Model Armor テンプレート

`make gcp-model-armor` → `./scripts/gcp_model_armor.sh` の実体（前半）:

```bash
gcloud model-armor templates create ma-egress \
  --location="$LOCATION" \
  --pi-and-jailbreak-filter-settings-enforcement=enabled \
  --pi-and-jailbreak-filter-settings-confidence-level=medium-and-above \
  --malicious-uri-filter-settings-enforcement=enabled
```

検査対象: **プロンプトインジェクション / ジェイルブレイク**、**悪意ある URI**

- `confidence-level` は `medium-and-above`。`low` まで拾うと誤検知が増える
- **テンプレートは Gateway と同じリージョンに作る必要がある**

---

## Model Armor: 呼び出す側の権限

実体（後半）:

```bash
PROJECT_NUMBER=$(gcloud projects describe "$GOOGLE_CLOUD_PROJECT" \
                   --format='value(projectNumber)')
SA="service-${PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com"

for ROLE in roles/modelarmor.calloutUser \
            roles/serviceusage.serviceUsageConsumer \
            roles/modelarmor.user; do
  gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
    --member="serviceAccount:${SA}" --role="$ROLE" --quiet
done
```

> ここは**エージェントではなく Google 管理のサービスエージェント**に付ける。
> 検査を呼び出す側の権限なので `serviceAccount:`。
> エージェント自身の権限（`principal://`）とは別物

---

## 運用: 必ず「観察」から始める

| 設定 | 初期値 | 昇格先 |
|---|---|---|
| Model Armor | `INSPECT_ONLY` | 遮断 |
| IAP 認可 | `DRY_RUN` | `ENFORCED` |

1. まず**ログだけ**取る
2. 何が検知されるかを確認する
3. 誤検知を解消する
4. **それから**遮断に上げる

> 最初から遮断で入れると、業務が止まってから原因を探すことになる。
> 統制レイヤは後から強くできるので、弱く入れて観察するのが定石

---

## 全体の依存関係

```
ローカル:  install → run → card → smoke → chat
                （uv sync）  （uvicorn） （agents-cli run --mode a2a）（playground）

GCP:      gcp-apis → gcp-deploy → gcp-iam → gcp-registry → gcp-gateway → gcp-model-armor
                         │            ↑          ↑
                         ├─ SPIFFE ID ┘          │（デプロイ出力を控えて渡す）
                         └─ Cloud Run の URL ────┘（fx-agent の手動登録に要る）

scaffold 時: --agent-gateway ──────────→ deploy --agent-gateway-egress
             --deployment-target ──────→ deploy の分岐先（Runtime / Cloud Run）
```

- `agents-cli deploy` は `app/agent.py` をそのままコンテナに載せる
  → **ローカルで動かないものはデプロイしても動かない**

---

## 罠まとめ

- `APP_URL` は **bind しない**。uvicorn の `--port` と食い違うと到達不能な URL が広告される
  （未設定だと `http://0.0.0.0:8000`）
- カードのパスは `/a2a/{App.name}/.well-known/agent-card.json`。ルート直下は 404
- `agents-cli run --mode a2a --url` には**ベース URL**を渡す（`/a2a/app` は CLI が足す）
- `RemoteA2aAgent(use_legacy=)` の既定は `True`。新統合は明示的に `False`
- リモートを `sub_agents` に置くと `transfer_to_agent` で制御ごと渡って**戻らない**。
  `AgentTool` で包む（`RemoteA2aAgent` は `mode='single_turn'` を持てない）
- `scaffold --agent-gateway` と `deploy --agent-gateway-egress` は**別物**。前者が前提
- `--agent-identity` は **Agent Runtime 専用**。Cloud Run へのデプロイでは無視される
- `app/fast_api_app.py` / `app/app_utils/*` は生成物。**A2A のコードは手書きしない**
- `make chat` と `make run` は独立。UI だけ起動しても繋がらない
- Agent Identity は**組織必須**。**長期鍵は存在しない**
- IAM は SA ではなく **`principal://`** に付ける
- Agent Registry への登録は **`agents-cli publish` では出来ない**（gcloud を使う）。
  **Agent Runtime の外にいるエージェントは deploy では名簿に載らない**
- Model Armor / IAP は **INSPECT_ONLY / DRY_RUN から**

---

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| `ModuleNotFoundError` | 依存が未導入 | `make install` |
| `port 18001 は既に他プロセスが使用中` | 別プロセスが占有（プロセス名が表示される） | 解放 or ポート変更 |
| カードの url が `http://0.0.0.0:8000` | `APP_URL` 未設定で起動した | `make run` 経由で起動 |
| カード取得が 404 | ルート直下を見ている | `/a2a/app/.well-known/agent-card.json` |
| `agents-cli run` が 404 | `--url` に `/a2a/app` まで書いた | ベース URL を渡す |
| 対話がつながらない | `make run` していない | 先に `make run` |
| 委譲が1体目で止まる | リモートを `sub_agents` に置いた | `AgentTool` で包む（罠⑥） |
| 外貨なのに fx_agent が呼ばれない | `currency` が返っていない / fx-agent が落ちている | `make card` で3体分出るか確認 |
| Registry 解決で `agents/fx-agent` が無い | Cloud Run の分は deploy が登録しない | `AGENT_BASE_URL=... make gcp-registry` |
| `make stop` で make ごと終了する | `pkill` パターンが自分に一致 | `[a]pp\.fast_api_app` と書く |

ログは `.logs/receipt-agent.log` / `.logs/policy-agent.log` / `.logs/fx-agent.log`

---

## 理解の要点

**A2A は「カードを取る → カードの URL に送る」の2段構え**
罠はほぼ全部この2段のどこかにある。`APP_URL` の食い違いも、パスの違いも

**A2A のコードは書かない。scaffold が生成したものを使う**
バージョン差の吸収を自分で引き受けない。触るのは `app/agent.py` だけ

**統制は身分・名簿・出口・検査の4層**
どれも後から強くできる形で入る。だから弱く入れて観察してから締める

**役割を分けることが、権限を分けられることに直結する**
エージェントの分割は機能の都合で決めがちだが、
そのままセキュリティ境界になる

**ランタイムが違っても A2A は変わらない**
変わるのは統制の当て方だけ — 身分の出どころ、名簿への載せ方、
呼ばれる側の守り方。プロトコルの上には何も出てこない

---

## 付録: 残りの make ターゲット

```bash
# make help — Makefile から `## ` 付きの行を抜き出して整形するだけ
grep -E '^[a-zA-Z_-]+:.*?## ' Makefile \
  | awk -F':.*?## ' '{printf "  \033[1m%-16s\033[0m %s\n", $1, $2}'

# make lint / make test — 4プロジェクトに流す
cd <proj> && agents-cli lint
cd <proj> && uv run pytest tests/unit tests/integration

# make clean — stop してから生成物を削除
rm -rf .pids .logs

# make gh-create REPO=owner/name / make push
gh repo create "$REPO" --public --source=. --remote=origin --push
git push -u origin main
```

---

## 付録: ポート事前検査マクロ

`make run` / `make chat` が起動前に呼ぶ `check_ports`:

```bash
for port in 18001 18002 18003; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: port $port は既に他プロセスが使用中です:"
    lsof -nP -iTCP:$port -sTCP:LISTEN | tail -n +2 | sed 's/^/  /'
    echo "  -> 解放するか、別ポートを指定: make <target> RECEIPT_PORT=.. POLICY_PORT=.. FX_PORT=.. WEB_PORT=.."
    exit 1
  fi
done
```

> ポート衝突が bind 失敗として現れないケース（別プロセスがそのポートで
> 正常に応答してしまう）があるため、起動前に検査している

---

## 付録: 環境変数の早見表

| 変数 | 置き場所 | 用途 |
|---|---|---|
| `WEB_PORT` / `RECEIPT_PORT` / `POLICY_PORT` / `FX_PORT` | make 引数 | **listen する**ポート（18000/18001/18002/18003） |
| `APP_URL` | Makefile が渡す（Cloud Run では deploy が入れる） | **カードに載る URL**（罠①） |
| `RECEIPT_AGENT_URL` / `POLICY_AGENT_URL` / `FX_AGENT_URL` | 環境 | 呼ぶ側の解決先 |
| `ADK_MODEL` | 各 `.env` | 既定 `gemini-3.7-flash`。4プロジェクト共通 |
| `GOOGLE_CLOUD_PROJECT` ほか | 各プロジェクトの `.env` | エージェントの認証・推論先 |
| `GOOGLE_CLOUD_PROJECT` / `GOOGLE_CLOUD_LOCATION` / `ORG_ID` / `STAGING_BUCKET` | ルートの `.env` | GCP 統制スクリプト共通 |
| `AGENT_GATEWAY` | ルートの `.env` | 設定時のみ `--agent-gateway-egress` を付ける |
| `AGENT_ENGINE_ID` | ルートの `.env` | `gcp-iam` で必要 |
| `AGENT_BASE_URL` / `SERVICE_NAME` | ルートの `.env` | `gcp-registry` で必要（fx-agent の手動登録） |
| `RECEIPTS_BUCKET` | ルートの `.env` | 設定時のみバケット権限を付与 |
| `FX_SERVICE_NAME` | ルートの `.env` | 設定時のみ `run.invoker` を付与（fx-agent を呼ぶ許可） |
| `USE_AGENT_REGISTRY` | 環境 | `1` で Registry 解決に切替 |

`.env` が2系統あるのが分かりにくい点。**エージェント自身の設定は各プロジェクト、
GCP 統制スクリプトの設定はルート**
