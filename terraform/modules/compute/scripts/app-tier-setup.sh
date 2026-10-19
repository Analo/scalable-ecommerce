#!/bin/bash
set -euo pipefail

# Template variables injected by Terraform templatefile()
# These lowercase names are substituted at plan/apply time.
DB_SECRET_ARN="${db_secret_arn}"
ENVIRONMENT="${environment}"
PROJECT_NAME="${project_name}"
REGION="${region}"
APP_PORT="${app_port}"

# ============================================================
# System update and package install
# ============================================================
dnf update -y
dnf install -y nodejs npm amazon-cloudwatch-agent aws-cli jq mariadb105

# ============================================================
# Fetch DB credentials from Secrets Manager
# ============================================================
DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "$${DB_SECRET_ARN}" \
  --region "$${REGION}" \
  --query SecretString \
  --output text)

DB_HOST=$(echo "$DB_SECRET" | jq -r '.host')
DB_PORT=$(echo "$DB_SECRET" | jq -r '.port')
DB_NAME=$(echo "$DB_SECRET" | jq -r '.dbname')
DB_USER=$(echo "$DB_SECRET" | jq -r '.username')
DB_PASS=$(echo "$DB_SECRET" | jq -r '.password')

# ============================================================
# Create application directory
# ============================================================
mkdir -p /opt/app-tier
useradd -r -s /bin/false webapp 2>/dev/null || true

# ============================================================
# Write application server
# ============================================================
cat > /opt/app-tier/app.js << 'APPEOF'
const express = require('express');
const mysql = require('mysql2/promise');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

const dbConfig = {
  host:     process.env.DB_HOST,
  port:     parseInt(process.env.DB_PORT, 10),
  database: process.env.DB_NAME,
  user:     process.env.DB_USER,
  password: process.env.DB_PASS,
  waitForConnections: true,
  connectionLimit:    10,
  queueLimit:         0
};

let pool;

async function getPool() {
  if (!pool) pool = await mysql.createPool(dbConfig);
  return pool;
}

// Create tables and seed sample data on first boot — idempotent via IF NOT EXISTS
async function initDb() {
  const db = await getPool();
  await db.query(`
    CREATE TABLE IF NOT EXISTS products (
      id          INT AUTO_INCREMENT PRIMARY KEY,
      name        VARCHAR(255)   NOT NULL,
      description TEXT,
      price       DECIMAL(10,2)  NOT NULL,
      stock       INT            NOT NULL DEFAULT 0,
      created_at  TIMESTAMP      DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await db.query(`
    CREATE TABLE IF NOT EXISTS orders (
      id               INT AUTO_INCREMENT PRIMARY KEY,
      product_id       INT,
      quantity         INT           NOT NULL,
      customer_email   VARCHAR(255)  NOT NULL,
      created_at       TIMESTAMP     DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (product_id) REFERENCES products(id)
    )
  `);
  const [[{ count }]] = await db.query('SELECT COUNT(*) AS count FROM products');
  if (count === 0) {
    await db.query(`
      INSERT INTO products (name, description, price, stock) VALUES
      ('Laptop Pro 15',   'High-performance 15-inch laptop',   999.99, 50),
      ('Wireless Mouse',  'Ergonomic wireless mouse',           29.99, 200),
      ('USB-C Hub 7-in-1','7-port USB-C hub with HDMI',         49.99, 150),
      ('Mechanical Keyboard', 'Tenkeyless mechanical keyboard', 79.99, 100)
    `);
  }
  console.log('Database initialised');
}

app.get('/health', async (req, res) => {
  try {
    const db = await getPool();
    await db.query('SELECT 1');
    res.status(200).json({ status: 'healthy', tier: 'app', db: 'connected' });
  } catch (err) {
    res.status(503).json({ status: 'unhealthy', error: err.message });
  }
});

app.get('/products', async (req, res) => {
  try {
    const db = await getPool();
    const [rows] = await db.query('SELECT * FROM products LIMIT 50');
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch products' });
  }
});

app.post('/orders', async (req, res) => {
  const { product_id, quantity, customer_email } = req.body;
  try {
    const db = await getPool();
    const [result] = await db.query(
      'INSERT INTO orders (product_id, quantity, customer_email, created_at) VALUES (?, ?, ?, NOW())',
      [product_id, quantity, customer_email]
    );
    res.status(201).json({ order_id: result.insertId });
  } catch (err) {
    res.status(500).json({ error: 'Failed to create order' });
  }
});

initDb()
  .then(() => app.listen(PORT, () => console.log(`App tier listening on port $${PORT}`)))
  .catch(err => { console.error('DB init failed:', err.message); process.exit(1); });
APPEOF

# ============================================================
# Install Node.js dependencies
# ============================================================
cd /opt/app-tier
npm init -y
npm install express mysql2

# ============================================================
# Write environment file
# ============================================================
cat > /opt/app-tier/.env << ENVEOF
NODE_ENV=$${ENVIRONMENT}
PORT=$${APP_PORT}
DB_HOST=$${DB_HOST}
DB_PORT=$${DB_PORT}
DB_NAME=$${DB_NAME}
DB_USER=$${DB_USER}
DB_PASS=$${DB_PASS}
ENVEOF

chmod 600 /opt/app-tier/.env

# ============================================================
# systemd service
# ============================================================
cat > /etc/systemd/system/app-tier.service << SVCEOF
[Unit]
Description=ScaleCommerce App Tier
After=network.target

[Service]
Type=simple
User=webapp
WorkingDirectory=/opt/app-tier
EnvironmentFile=/opt/app-tier/.env
ExecStart=/usr/bin/node app.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=app-tier

[Install]
WantedBy=multi-user.target
SVCEOF

chown -R webapp:webapp /opt/app-tier
chmod 750 /opt/app-tier

systemctl daemon-reload
systemctl enable app-tier
systemctl start app-tier

# ============================================================
# CloudWatch Agent configuration
# ============================================================
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWEOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/messages",
            "log_group_name": "/aws/ec2/$${PROJECT_NAME}-$${ENVIRONMENT}/app-tier/system",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  },
  "metrics": {
    "append_dimensions": {
      "InstanceId": "$${aws:InstanceId}",
      "AutoScalingGroupName": "$${aws:AutoScalingGroupName}"
    },
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": {
        "measurement": ["disk_used_percent"],
        "resources": ["/"]
      }
    }
  }
}
CWEOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
