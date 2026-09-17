$ErrorActionPreference = "Stop"
$Root = Get-Location
$Backend = Join-Path $Root "backend"
$Frontend = Join-Path $Root "frontend"
$K8s = Join-Path $Root "k8s"

Write-Host "=== CampusCare Full Local Setup ===" -ForegroundColor Cyan

foreach ($cmd in @("docker","kubectl","python")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "$cmd was not found. Install it and try again."
    }
}
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw "Start Docker Desktop first." }

New-Item -ItemType Directory -Force -Path $Backend,$Frontend,$K8s | Out-Null

@'
from flask import Flask, jsonify, request
import os
import psycopg

app = Flask(__name__)
DATABASE_URL = os.getenv("DATABASE_URL","postgresql://campuscare:campuscare@localhost:5432/campuscare")

def db():
    return psycopg.connect(DATABASE_URL)

def init_db():
    with db() as conn:
        with conn.cursor() as cur:
            cur.execute("""CREATE TABLE IF NOT EXISTS issues (
                id SERIAL PRIMARY KEY, title VARCHAR(200) NOT NULL,
                description TEXT NOT NULL, category VARCHAR(100) NOT NULL,
                priority VARCHAR(20) NOT NULL DEFAULT 'Medium',
                status VARCHAR(30) NOT NULL DEFAULT 'Pending',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""")
        conn.commit()

@app.get("/api/health")
def health():
    return jsonify(status="healthy", application="CampusCare")

@app.get("/api/issues")
def get_issues():
    with db() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id,title,description,category,priority,status,created_at FROM issues ORDER BY id DESC")
            rows = cur.fetchall()
    return jsonify([{"id":r[0],"title":r[1],"description":r[2],"category":r[3],"priority":r[4],"status":r[5],"created_at":r[6].isoformat() if r[6] else None} for r in rows])

@app.post("/api/issues")
def create_issue():
    data = request.get_json(silent=True) or {}
    missing = [x for x in ("title","description","category") if not data.get(x)]
    if missing: return jsonify(error="Missing required fields", fields=missing), 400
    with db() as conn:
        with conn.cursor() as cur:
            cur.execute("""INSERT INTO issues(title,description,category,priority)
                VALUES(%s,%s,%s,%s)
                RETURNING id,title,description,category,priority,status,created_at""",
                (data["title"],data["description"],data["category"],data.get("priority","Medium")))
            r=cur.fetchone()
        conn.commit()
    return jsonify({"id":r[0],"title":r[1],"description":r[2],"category":r[3],"priority":r[4],"status":r[5],"created_at":r[6].isoformat() if r[6] else None}),201

@app.put("/api/issues/<int:issue_id>")
def update_issue(issue_id):
    status=(request.get_json(silent=True) or {}).get("status")
    if status not in {"Pending","Working","Resolved"}:
        return jsonify(error="status must be Pending, Working, or Resolved"),400
    with db() as conn:
        with conn.cursor() as cur:
            cur.execute("UPDATE issues SET status=%s WHERE id=%s RETURNING id,title,description,category,priority,status,created_at",(status,issue_id))
            r=cur.fetchone()
        conn.commit()
    if not r: return jsonify(error="Issue not found"),404
    return jsonify({"id":r[0],"title":r[1],"description":r[2],"category":r[3],"priority":r[4],"status":r[5],"created_at":r[6].isoformat() if r[6] else None})

@app.get("/api/issues/<int:issue_id>")
def get_issue(issue_id):
    with db() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id,title,description,category,priority,status,created_at FROM issues WHERE id=%s",(issue_id,))
            r=cur.fetchone()
    if not r: return jsonify(error="Issue not found"),404
    return jsonify({"id":r[0],"title":r[1],"description":r[2],"category":r[3],"priority":r[4],"status":r[5],"created_at":r[6].isoformat() if r[6] else None})

if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0",port=5000)
'@ | Set-Content (Join-Path $Backend "app.py") -Encoding UTF8

@'
Flask==3.1.2
psycopg[binary]==3.2.10
'@ | Set-Content (Join-Path $Backend "requirements.txt") -Encoding UTF8

@'
FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 5000
CMD ["python","app.py"]
'@ | Set-Content (Join-Path $Backend "Dockerfile") -Encoding UTF8

@'
<!doctype html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width"><title>CampusCare</title>
<style>body{font-family:Arial;max-width:850px;margin:40px auto;padding:0 20px}.card{border:1px solid #ddd;border-radius:12px;padding:18px;margin:16px 0}input,textarea,select,button{width:100%;padding:10px;margin:7px 0 14px;box-sizing:border-box}button{cursor:pointer}.issue{border-left:5px solid #777}</style></head>
<body><h1>🏫 CampusCare</h1><p>Report and track college maintenance issues.</p>
<div class="card"><h2>Report an Issue</h2><input id="title" placeholder="Title"><textarea id="description" placeholder="Describe the problem"></textarea><input id="category" placeholder="Category"><select id="priority"><option>Low</option><option selected>Medium</option><option>High</option></select><button onclick="createIssue()">Submit Issue</button><p id="message"></p></div>
<div class="card"><h2>Issues</h2><div id="issues">Loading...</div></div>
<script>
const API="/api";
const esc=v=>String(v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[c]));
async function load(){let r=await fetch(API+"/issues"),a=await r.json();document.getElementById("issues").innerHTML=a.length?a.map(i=>`<div class="card issue"><h3>#${i.id} - ${esc(i.title)}</h3><p>${esc(i.description)}</p><p>Category: ${esc(i.category)} | Priority: ${esc(i.priority)}</p><b>Status: ${esc(i.status)}</b></div>`).join(""):"No issues yet."}
async function createIssue(){let p={title:title.value,description:description.value,category:category.value,priority:priority.value};let r=await fetch(API+"/issues",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(p)});let d=await r.json();message.textContent=r.ok?`Issue #${d.id} created!`:d.error; if(r.ok){title.value="";description.value="";category.value="";load()}}
load();
</script></body></html>
'@ | Set-Content (Join-Path $Frontend "index.html") -Encoding UTF8

@'
services:
  db:
    image: postgres:16-alpine
    container_name: campuscare-db
    environment:
      POSTGRES_DB: campuscare
      POSTGRES_USER: campuscare
      POSTGRES_PASSWORD: campuscare
    volumes: [campuscare_db_data:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U campuscare -d campuscare"]
      interval: 5s
      timeout: 5s
      retries: 10
  backend:
    build: ./backend
    container_name: campuscare-backend
    environment:
      DATABASE_URL: postgresql://campuscare:campuscare@db:5432/campuscare
    depends_on:
      db: {condition: service_healthy}
    ports: ["5000:5000"]
  frontend:
    image: nginx:alpine
    container_name: campuscare-frontend
    volumes:
      - ./frontend:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on: [backend]
    ports: ["8080:80"]
volumes:
  campuscare_db_data:
'@ | Set-Content (Join-Path $Root "docker-compose.yml") -Encoding UTF8

@'
server {
 listen 80; root /usr/share/nginx/html; index index.html;
 location / { try_files $uri $uri/ /index.html; }
 location /api/ { proxy_pass http://backend:5000/api/; proxy_set_header Host $host; }
}
'@ | Set-Content (Join-Path $Root "nginx.conf") -Encoding UTF8

@'
apiVersion: v1
kind: Namespace
metadata: {name: campuscare}
---
apiVersion: v1
kind: Secret
metadata: {name: campuscare-db, namespace: campuscare}
type: Opaque
stringData: {POSTGRES_DB: campuscare, POSTGRES_USER: campuscare, POSTGRES_PASSWORD: campuscare}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: campuscare-db-pvc, namespace: campuscare}
spec:
 accessModes: [ReadWriteOnce]
 resources: {requests: {storage: 1Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: postgres, namespace: campuscare}
spec:
 replicas: 1
 selector: {matchLabels: {app: postgres}}
 template:
  metadata: {labels: {app: postgres}}
  spec:
   containers:
   - name: postgres
     image: postgres:16-alpine
     envFrom: [{secretRef: {name: campuscare-db}}]
     ports: [{containerPort: 5432}]
     volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
     readinessProbe: {exec: {command: ["sh","-c","pg_isready -U campuscare -d campuscare"]}, initialDelaySeconds: 5, periodSeconds: 5}
   volumes: [{name: data, persistentVolumeClaim: {claimName: campuscare-db-pvc}}]
---
apiVersion: v1
kind: Service
metadata: {name: postgres, namespace: campuscare}
spec:
 selector: {app: postgres}
 ports: [{port: 5432, targetPort: 5432}]
'@ | Set-Content (Join-Path $K8s "postgres.yaml") -Encoding UTF8

@'
apiVersion: apps/v1
kind: Deployment
metadata: {name: backend, namespace: campuscare}
spec:
 replicas: 2
 selector: {matchLabels: {app: backend}}
 template:
  metadata: {labels: {app: backend}}
  spec:
   containers:
   - name: backend
     image: campuscare-backend:latest
     imagePullPolicy: IfNotPresent
     env: [{name: DATABASE_URL, value: "postgresql://campuscare:campuscare@postgres:5432/campuscare"}]
     ports: [{containerPort: 5000}]
     readinessProbe: {httpGet: {path: /api/health, port: 5000}, initialDelaySeconds: 5, periodSeconds: 5}
     livenessProbe: {httpGet: {path: /api/health, port: 5000}, initialDelaySeconds: 10, periodSeconds: 10}
---
apiVersion: v1
kind: Service
metadata: {name: backend, namespace: campuscare}
spec:
 selector: {app: backend}
 ports: [{port: 5000, targetPort: 5000}]
'@ | Set-Content (Join-Path $K8s "backend.yaml") -Encoding UTF8

@'
apiVersion: apps/v1
kind: Deployment
metadata: {name: frontend, namespace: campuscare}
spec:
 replicas: 2
 selector: {matchLabels: {app: frontend}}
 template:
  metadata: {labels: {app: frontend}}
  spec:
   containers:
   - name: frontend
     image: nginx:alpine
     ports: [{containerPort: 80}]
     volumeMounts:
     - {name: site, mountPath: /usr/share/nginx/html}
     - {name: config, mountPath: /etc/nginx/conf.d/default.conf, subPath: default.conf}
   volumes:
   - name: site
     configMap: {name: frontend-site}
   - name: config
     configMap: {name: frontend-nginx}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: frontend-site, namespace: campuscare}
data:
 index.html: |
  <!doctype html><html><body style="font-family:Arial;max-width:800px;margin:40px auto"><h1>CampusCare 🏫</h1><p>Kubernetes frontend is running.</p><p><a href="/api/health">Backend health</a></p></body></html>
---
apiVersion: v1
kind: ConfigMap
metadata: {name: frontend-nginx, namespace: campuscare}
data:
 default.conf: |
  server { listen 80; root /usr/share/nginx/html; index index.html; location / { try_files $uri $uri/ /index.html; } location /api/ { proxy_pass http://backend:5000/api/; proxy_set_header Host $host; } }
---
apiVersion: v1
kind: Service
metadata: {name: frontend, namespace: campuscare}
spec:
 type: NodePort
 selector: {app: frontend}
 ports: [{port: 80, targetPort: 80, nodePort: 30080}]
'@ | Set-Content (Join-Path $K8s "frontend.yaml") -Encoding UTF8

Write-Host "[1/4] Building backend image..." -ForegroundColor Yellow
docker build -t campuscare-backend:latest $Backend

Write-Host "[2/4] Starting full Docker stack..." -ForegroundColor Yellow
docker compose down --remove-orphans 2>$null
docker compose up -d --build

Write-Host "[3/4] Waiting for backend..." -ForegroundColor Yellow
for($i=0;$i -lt 30;$i++){
 try { $r=Invoke-RestMethod http://localhost:5000/api/health -TimeoutSec 2; if($r.status -eq "healthy"){break} } catch {}
 Start-Sleep 2
}
$r=Invoke-RestMethod http://localhost:5000/api/health
if($r.status -ne "healthy"){throw "Backend health check failed."}

Write-Host "[4/4] Deploying to Kubernetes..." -ForegroundColor Yellow
kubectl apply -f (Join-Path $K8s "postgres.yaml")
kubectl apply -f (Join-Path $K8s "backend.yaml")
kubectl apply -f (Join-Path $K8s "frontend.yaml")

Write-Host ""
Write-Host "=== DONE ===" -ForegroundColor Green
Write-Host "Full Docker app: http://localhost:8080" -ForegroundColor Green
Write-Host "Backend API:     http://localhost:5000/api/health" -ForegroundColor Green
Write-Host "Kubernetes pods: kubectl get pods -n campuscare" -ForegroundColor Cyan
Write-Host "Kubernetes svc:  kubectl get services -n campuscare" -ForegroundColor Cyan