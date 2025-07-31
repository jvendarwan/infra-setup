#!/bin/bash
# Airflow Setup Script for t2.micro Ubuntu 23.04
# Run this script on your EC2 instance

set -e  # Exit on any error

echo "🚀 Setting up Apache Airflow on t2.micro..."

# Update system
sudo apt update && sudo apt upgrade -y

# Install Python 3.11 and pip
sudo apt install -y python3.11 python3.11-venv python3.11-dev python3-pip
sudo apt install -y build-essential libssl-dev libffi-dev
sudo apt install -y postgresql-client  # For potential future use

# Create airflow user (optional but recommended)
sudo useradd -m -s /bin/bash airflow || true
sudo usermod -aG sudo airflow

# Switch to airflow user for setup
sudo -u airflow bash << 'EOF'

# Set up Airflow home directory
export AIRFLOW_HOME=/home/airflow/airflow
mkdir -p $AIRFLOW_HOME

# Create Python virtual environment
cd /home/airflow
python3.11 -m venv airflow-venv
source airflow-venv/bin/activate

# Upgrade pip
pip install --upgrade pip

# Install Airflow (constrained version for stability)
# Using SQLite and SequentialExecutor for t2.micro limitations
AIRFLOW_VERSION=2.8.1
PYTHON_VERSION="$(python --version | cut -d " " -f 2 | cut -d "." -f 1-2)"
CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"

pip install "apache-airflow==${AIRFLOW_VERSION}" --constraint "${CONSTRAINT_URL}"

# Install additional providers for AWS
pip install apache-airflow-providers-amazon
pip install apache-airflow-providers-http
pip install requests boto3

# Initialize Airflow database (SQLite for simplicity)
export AIRFLOW_HOME=/home/airflow/airflow
airflow db init

# Create admin user
airflow users create \
    --username admin \
    --password admin123 \
    --firstname Admin \
    --lastname User \
    --role Admin \
    --email admin@example.com

EOF

# Configure Airflow for t2.micro limitations
sudo -u airflow bash << 'EOF'
export AIRFLOW_HOME=/home/airflow/airflow

# Create airflow.cfg with t2.micro optimizations
cat > $AIRFLOW_HOME/airflow.cfg << 'CONFIG_EOF'
[core]
# SQLite database (suitable for single node)
sql_alchemy_conn = sqlite:////home/airflow/airflow/airflow.db

# SequentialExecutor - no parallelism (t2.micro limitation)
executor = SequentialExecutor

# Reduce memory usage
parallelism = 1
max_active_tasks_per_dag = 1
max_active_runs_per_dag = 1

# DAG settings
dags_folder = /home/airflow/airflow/dags
load_examples = False
store_serialized_dags = True

# Reduce log retention to save space
max_log_files_retention_count = 5

[scheduler]
# Reduce scheduler overhead
dag_dir_list_interval = 300
job_heartbeat_sec = 30
scheduler_heartbeat_sec = 30
num_runs = 1

[webserver]
# Web server settings
web_server_host = 0.0.0.0
web_server_port = 8080
secret_key = your-secret-key-change-this
expose_config = True
authenticate = False
rbac = True

# Reduce worker processes for t2.micro
workers = 1
worker_refresh_batch_size = 1

[celery]
# Not used with SequentialExecutor, but keeping for future
broker_url = 
result_backend = 

[logging]
# Reduce logging overhead
logging_level = WARNING
fab_logging_level = WARNING

[api]
auth_backends = airflow.api.auth.backend.basic_auth

CONFIG_EOF

# Create dags directory
mkdir -p $AIRFLOW_HOME/dags
mkdir -p $AIRFLOW_HOME/logs
mkdir -p $AIRFLOW_HOME/plugins

EOF

# Create systemd service files for auto-start
echo "📝 Creating systemd services..."

# Airflow Webserver Service
sudo tee /etc/systemd/system/airflow-webserver.service > /dev/null << 'EOF'
[Unit]
Description=Airflow webserver daemon
After=network.target

[Service]
Type=simple
User=airflow
Group=airflow
Environment=AIRFLOW_HOME=/home/airflow/airflow
Environment=PATH=/home/airflow/airflow-venv/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/airflow/airflow-venv/bin/airflow webserver --port 8080
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Airflow Scheduler Service  
sudo tee /etc/systemd/system/airflow-scheduler.service > /dev/null << 'EOF'
[Unit]
Description=Airflow scheduler daemon
After=network.target

[Service]
Type=simple
User=airflow
Group=airflow
Environment=AIRFLOW_HOME=/home/airflow/airflow
Environment=PATH=/home/airflow/airflow-venv/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/airflow/airflow-venv/bin/airflow scheduler
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Enable and start services
sudo systemctl daemon-reload
sudo systemctl enable airflow-webserver
sudo systemctl enable airflow-scheduler
sudo systemctl start airflow-webserver
sudo systemctl start airflow-scheduler

# Set up log rotation to prevent disk space issues
sudo tee /etc/logrotate.d/airflow > /dev/null << 'EOF'
/home/airflow/airflow/logs/*.log {
    daily
    missingok
    rotate 7
    compress
    notifempty
    sharedscripts
}
EOF

# Configure security group reminder
echo ""
echo "🔒 SECURITY GROUP CONFIGURATION NEEDED:"
echo "   Go to AWS Console > EC2 > Security Groups"
echo "   Add Inbound Rule: Type=Custom TCP, Port=8080, Source=0.0.0.0/0"
echo ""

# Check service status
echo "📊 Service Status:"
sleep 10
sudo systemctl status airflow-webserver --no-pager -l
sudo systemctl status airflow-scheduler --no-pager -l

# Final instructions
echo ""
echo "✅ Airflow setup complete!"
echo ""
echo "🌐 Access Airflow at: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):8080"
echo "👤 Login: admin / admin123"
echo ""
echo "📁 DAGs folder: /home/airflow/airflow/dags"
echo "📝 Logs folder: /home/airflow/airflow/logs"
echo ""
echo "🔧 Useful commands:"
echo "   sudo systemctl restart airflow-webserver"
echo "   sudo systemctl restart airflow-scheduler"
echo "   sudo -u airflow bash"
echo "   source /home/airflow/airflow-venv/bin/activate"
echo ""

# Memory usage warning
echo "⚠️  WARNING: t2.micro has only 1GB RAM!"
echo "   Monitor memory usage: free -m"
echo "   Consider upgrading to t3.small for better performance"
echo ""

# Create a simple test DAG
sudo -u airflow bash << 'EOF'
export AIRFLOW_HOME=/home/airflow/airflow

cat > $AIRFLOW_HOME/dags/test_dag.py << 'DAG_EOF'
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator

def hello_world():
    print("Hello from Airflow on t2.micro!")
    return "success"

default_args = {
    'owner': 'bitcoin-mlops',
    'depends_on_past': False,
    'start_date': datetime(2024, 1, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

dag = DAG(
    'test_dag',
    default_args=default_args,
    description='Simple test DAG',
    schedule_interval=None,  # Manual trigger only
    catchup=False,
    tags=['test'],
)

task1 = PythonOperator(
    task_id='hello_world_task',
    python_callable=hello_world,
    dag=dag,
)
DAG_EOF

EOF

echo "🎯 Test DAG created: test_dag"
echo "   You can trigger it from the Airflow web UI to test the setup"