from flask import Flask, jsonify, request, session, redirect, send_from_directory
from werkzeug.security import generate_password_hash, check_password_hash
import os, secrets, smtplib, requests
from email.message import EmailMessage
from urllib.parse import urlencode
import psycopg

app = Flask(__name__)
app.config["SECRET_KEY"] = os.getenv("FLASK_SECRET_KEY", secrets.token_hex(32))
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
app.config["SESSION_COOKIE_HTTPONLY"] = True
if os.getenv("VERCEL") == "1" or os.getenv("SESSION_COOKIE_SECURE", "").lower() in ("1", "true"):
    app.config["SESSION_COOKIE_SECURE"] = True

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://campuscare:campuscare@localhost:5432/campuscare")
if DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql://", 1)

ADMIN_EMAIL = os.getenv("ADMIN_EMAIL", "").strip().lower()
GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET = os.getenv("GOOGLE_CLIENT_ID", ""), os.getenv("GOOGLE_CLIENT_SECRET", "")
GOOGLE_REDIRECT_URI = os.getenv("GOOGLE_REDIRECT_URI", "")
SMTP_HOST, SMTP_PORT = os.getenv("SMTP_HOST", "smtp.gmail.com"), int(os.getenv("SMTP_PORT", "587"))
SMTP_USER, SMTP_PASSWORD = os.getenv("SMTP_USER", ""), os.getenv("SMTP_PASSWORD", "").replace(" ", "")

def db(): return psycopg.connect(DATABASE_URL)
def init_db():
    with db() as conn:
        with conn.cursor() as cur:
            cur.execute("""CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY,email VARCHAR(254) UNIQUE NOT NULL,password_hash TEXT,name VARCHAR(120),google_id VARCHAR(255) UNIQUE,created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""")
            cur.execute("""CREATE TABLE IF NOT EXISTS issues (id SERIAL PRIMARY KEY,title VARCHAR(200) NOT NULL,description TEXT NOT NULL,category VARCHAR(100) NOT NULL,priority VARCHAR(20) NOT NULL DEFAULT 'Medium',status VARCHAR(30) NOT NULL DEFAULT 'Pending',created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""")
            cur.execute("ALTER TABLE issues ADD COLUMN IF NOT EXISTS user_id INTEGER REFERENCES users(id) ON DELETE SET NULL")
        conn.commit()
def user_payload(row): return {"id":row[0],"email":row[1],"name":row[2] or row[1].split("@")[0],"is_admin":row[1].lower()==ADMIN_EMAIL}
def current_user():
    if not session.get("user_id"): return None
    with db() as conn:
        with conn.cursor() as cur: cur.execute("SELECT id,email,name FROM users WHERE id=%s",(session["user_id"],)); row=cur.fetchone()
    return user_payload(row) if row else None
def required():
    user=current_user()
    return user,(None if user else (jsonify(error="Please sign in to continue."),401))
def email(recipient,subject,body):
    if not(recipient and SMTP_USER and SMTP_PASSWORD): return
    message=EmailMessage();message["From"]=f"CampusCare <{SMTP_USER}>";message["To"]=recipient;message["Subject"]=subject;message.set_content(body)
    try:
        with smtplib.SMTP(SMTP_HOST,SMTP_PORT,timeout=12) as smtp: smtp.starttls();smtp.login(SMTP_USER,SMTP_PASSWORD);smtp.send_message(message)
    except Exception as error: app.logger.warning("Notification email could not be sent: %s",error)
def payload(row): return {"id":row[0],"title":row[1],"description":row[2],"category":row[3],"priority":row[4],"status":row[5],"created_at":row[6].isoformat() if row[6] else None,"reporter_name":row[7],"reporter_email":row[8],"user_id":row[9]}

@app.get("/api/health")
def health(): return jsonify(status="healthy",application="CampusCare")
@app.route("/api/index")
@app.route("/api/index.py")
def debug_vercel():
    return jsonify({
        "path_info": request.environ.get("PATH_INFO"),
        "request_uri": request.environ.get("REQUEST_URI"),
        "x_forwarded_uri": request.headers.get("X-Forwarded-Uri"),
        "x_matched_path": request.headers.get("X-Matched-Path"),
        "headers": {k: v for k, v in request.headers.items() if "cookie" not in k.lower() and "auth" not in k.lower()}
    })
@app.get("/api/auth/status")
def auth_status(): return jsonify(user=current_user())
@app.post("/api/auth/register")
def register():
    data=request.get_json(silent=True) or {};email_address=data.get("email","").strip().lower();password=data.get("password","");name=data.get("name","").strip()
    if not email_address or "@" not in email_address or len(password)<8:return jsonify(error="Enter a valid email and a password with at least 8 characters."),400
    with db() as conn:
        with conn.cursor() as cur:cur.execute("INSERT INTO users(email,password_hash,name) VALUES(%s,%s,%s) ON CONFLICT(email) DO NOTHING RETURNING id,email,name",(email_address,generate_password_hash(password),name));row=cur.fetchone()
        conn.commit()
    if not row:return jsonify(error="An account already exists for this email. Please sign in."),409
    session["user_id"]=row[0];return jsonify(user=user_payload(row)),201
@app.post("/api/auth/login")
def login():
    data=request.get_json(silent=True) or {};email_address=data.get("email","").strip().lower();password=data.get("password","")
    with db() as conn:
        with conn.cursor() as cur:cur.execute("SELECT id,email,password_hash,name FROM users WHERE email=%s",(email_address,));row=cur.fetchone()
    if not row or not row[2] or not check_password_hash(row[2],password):return jsonify(error="Incorrect email or password."),401
    session["user_id"]=row[0];return jsonify(user=user_payload((row[0],row[1],row[3])))
@app.post("/api/auth/logout")
def logout():session.clear();return jsonify(message="Signed out")
@app.get("/api/auth/google")
def google_login():
    if not(GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET):return jsonify(error="Google sign-in has not been configured."),503
    redirect_uri = GOOGLE_REDIRECT_URI or f"{request.scheme}://{request.host}/api/auth/google/callback"
    state=secrets.token_urlsafe(24);session["oauth_state"]=state
    return redirect("https://accounts.google.com/o/oauth2/v2/auth?"+urlencode({"client_id":GOOGLE_CLIENT_ID,"redirect_uri":redirect_uri,"response_type":"code","scope":"openid email profile","state":state,"prompt":"select_account"}))
@app.get("/api/auth/google/callback")
def google_callback():
    redirect_uri = GOOGLE_REDIRECT_URI or f"{request.scheme}://{request.host}/api/auth/google/callback"
    if request.args.get("state")!=session.pop("oauth_state",None):return redirect("/#login-error")
    try:
        token=requests.post("https://oauth2.googleapis.com/token",data={"code":request.args["code"],"client_id":GOOGLE_CLIENT_ID,"client_secret":GOOGLE_CLIENT_SECRET,"redirect_uri":redirect_uri,"grant_type":"authorization_code"},timeout=10).json()
        profile=requests.get("https://openidconnect.googleapis.com/v1/userinfo",headers={"Authorization":f"Bearer {token['access_token']}"},timeout=10).json();email_address,google_id,name=profile["email"].lower(),profile["sub"],profile.get("name","")
    except Exception:return redirect("/#login-error")
    with db() as conn:
        with conn.cursor() as cur:cur.execute("INSERT INTO users(email,name,google_id) VALUES(%s,%s,%s) ON CONFLICT(email) DO UPDATE SET name=EXCLUDED.name,google_id=EXCLUDED.google_id RETURNING id,email,name",(email_address,name,google_id));row=cur.fetchone()
        conn.commit()
    session["user_id"]=row[0];return redirect("/#dashboard")
@app.get("/api/issues")
def get_issues():
    user,error=required()
    if error:return error
    query="SELECT i.id,i.title,i.description,i.category,i.priority,i.status,i.created_at,u.name,u.email,i.user_id FROM issues i LEFT JOIN users u ON u.id=i.user_id";params=()
    if not user["is_admin"]:query+=" WHERE i.user_id=%s";params=(user["id"],)
    query+=" ORDER BY i.id DESC"
    with db() as conn:
        with conn.cursor() as cur:cur.execute(query,params);rows=cur.fetchall()
    return jsonify([payload(row) for row in rows])
@app.post("/api/issues")
def create_issue():
    user,error=required()
    if error:return error
    data=request.get_json(silent=True) or {};missing=[field for field in("title","description","category") if not data.get(field)]
    if missing:return jsonify(error="Missing required fields",fields=missing),400
    with db() as conn:
        with conn.cursor() as cur:cur.execute("INSERT INTO issues(title,description,category,priority,user_id) VALUES(%s,%s,%s,%s,%s) RETURNING id,title,description,category,priority,status,created_at",(data["title"],data["description"],data["category"],data.get("priority","Medium"),user["id"]));row=cur.fetchone()
        conn.commit()
    issue={"id":row[0],"title":row[1],"description":row[2],"category":row[3],"priority":row[4],"status":row[5],"created_at":row[6].isoformat() if row[6] else None,"reporter_name":user["name"],"reporter_email":user["email"],"user_id":user["id"]}
    email(ADMIN_EMAIL,f"New CampusCare report #{issue['id']}: {issue['title']}",f"New report from {user['name']} ({user['email']}).\n\nCategory: {issue['category']}\nPriority: {issue['priority']}\n\n{issue['description']}")
    email(user["email"],f"CampusCare report #{issue['id']} submitted",f"Hi {user['name']},\n\nWe received your report: {issue['title']}\nCurrent status: Pending\n\nThe CampusCare team will review it shortly.")
    return jsonify(issue),201
@app.put("/api/issues/<int:issue_id>")
def update_issue(issue_id):
    user,error=required()
    if error:return error
    if not user["is_admin"]:return jsonify(error="Only the CampusCare administrator can update status."),403
    status=(request.get_json(silent=True) or {}).get("status")
    if status not in {"Pending","Working","Resolved"}:return jsonify(error="status must be Pending, Working, or Resolved"),400
    with db() as conn:
        with conn.cursor() as cur:cur.execute("UPDATE issues SET status=%s WHERE id=%s RETURNING id,title,description,category,priority,status,created_at",(status,issue_id));row=cur.fetchone()
        conn.commit()
    if not row:return jsonify(error="Issue not found"),404
    return jsonify({"id":row[0],"title":row[1],"description":row[2],"category":row[3],"priority":row[4],"status":row[5],"created_at":row[6].isoformat() if row[6] else None})
@app.delete("/api/issues/<int:issue_id>")
def delete_issue(issue_id):
    user,error=required()
    if error:return error
    with db() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT user_id FROM issues WHERE id=%s",(issue_id,));owner=cur.fetchone()
            if not owner:return jsonify(error="Issue not found"),404
            if not user["is_admin"] and owner[0]!=user["id"]:return jsonify(error="You can delete only your own reports."),403
            cur.execute("DELETE FROM issues WHERE id=%s",(issue_id,))
        conn.commit()
    return jsonify(message="Issue deleted")

# Static frontend fallback handler (useful for Vercel serverless executions)
FRONTEND_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "public")
if not os.path.exists(FRONTEND_DIR):
    FRONTEND_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "frontend")

@app.route("/")
def serve_root():
    return send_from_directory(FRONTEND_DIR, "index.html")

@app.route("/<path:path>")
def serve_fallback_static(path):
    if os.path.exists(os.path.join(FRONTEND_DIR, path)):
        return send_from_directory(FRONTEND_DIR, path)
    return jsonify(error="Not Found", path=path), 404

class ApiPrefixMiddleware:
    def __init__(self, wsgi_app):
        self.wsgi_app = wsgi_app
    def __call__(self, environ, start_response):
        qs = environ.get('QUERY_STRING', '')
        if '__path=' in qs:
            from urllib.parse import parse_qs, urlencode
            params = parse_qs(qs, keep_blank_values=True)
            if '__path' in params and params['__path']:
                subpath = params['__path'][0]
                if not subpath.startswith('/'):
                    subpath = '/' + subpath
                environ['PATH_INFO'] = '/api' + subpath
                del params['__path']
                environ['QUERY_STRING'] = urlencode(params, doseq=True)
        else:
            path = environ.get('PATH_INFO', '')
            if path and not path.startswith('/api'):
                for prefix in ('/auth', '/issues', '/health'):
                    if path.startswith(prefix):
                        environ['PATH_INFO'] = '/api' + path
                        break
        return self.wsgi_app(environ, start_response)

app.wsgi_app = ApiPrefixMiddleware(app.wsgi_app)

if __name__=="__main__":init_db();app.run(host="0.0.0.0",port=5000)
