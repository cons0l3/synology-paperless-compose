# Paperless-NGX for Synology NAS

A Docker Compose configuration for running [Paperless-NGX](https://docs.paperless-ngx.com/) on Synology NAS devices. This setup is optimized for Synology DSM and includes PostgreSQL 18, Redis, Apache Tika, and Gotenberg for comprehensive document management.

## What is Paperless-NGX?

Paperless-NGX is a document management system that transforms your physical documents into a searchable online archive. It automatically:
- Scans and imports documents
- Performs OCR (Optical Character Recognition)
- Extracts metadata and indexes content
- Supports Office documents (Word, Excel, PowerPoint)
- Provides a web interface for document management

## Prerequisites

### Hardware Requirements
- **Synology NAS** with DSM 7.0 or later
- At least **2GB RAM** (4GB+ recommended for optimal performance)
- Sufficient storage space for your documents

### Software Requirements
- **Docker** package installed from Synology Package Center
- **Docker Compose** (usually included with Docker package)
- SSH access to your Synology NAS (for setup)

### Network Requirements
- Port 8000 available for the web interface
- Port 15432 available for PostgreSQL access (optional)

## Architecture

This setup includes the following services:
- **Paperless-NGX webserver** - Main application interface
- **PostgreSQL 18** - Database backend for document metadata
- **Redis 8** - Message broker for background tasks
- **Apache Tika** - Office document processing
- **Gotenberg** - PDF conversion and processing

## Installation

### 1. Clone or Download the Repository

SSH into your Synology NAS and clone this repository:

```bash
cd /volume1/docker  # Or your preferred Docker directory
git clone https://github.com/cons0l3/synology-paperless-compose.git
cd synology-paperless-compose
```

Alternatively, download the files manually via the Synology File Station.

### 2. Configure Environment Variables

Copy the sample environment file and customize it:

```bash
cp docker-compose.env.sample docker-compose.env
```

Edit `docker-compose.env` with your preferred text editor:

```bash
nano docker-compose.env
```

**Required configurations:**

```env
# The URL where Paperless will be accessible
PAPERLESS_URL=http://your-nas-ip:8000

# User mapping for file permissions
USERMAP_UID=1028  # Your Synology user ID (check with `id` command)
USERMAP_GID=100   # Users group on Synology

# Time zone (important for correct document dates)
PAPERLESS_TIME_ZONE=Europe/Berlin

# OCR language (use ISO 639-2 codes)
PAPERLESS_OCR_LANGUAGE=deu  # German, use 'eng' for English

# Secret key for Django (generate a random string)
PAPERLESS_SECRET_KEY=your-secret-key-here
```

**To generate a secure secret key:**
```bash
tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 64
```

### 3. Adjust Storage Paths (Optional)

The default configuration uses the following paths on your Synology NAS:
- `/volume1/data_store/PaperlessStore/data` - Application data
- `/volume1/data_store/PaperlessStore/media` - Stored documents
- `/volume1/data_store/PaperlessStore/Consume` - Incoming documents folder
- `/volume1/data_store/PaperlessStore/db18` - PostgreSQL database files

**To customize paths**, edit `docker-compose.yml`:

```yaml
volumes:
  - /your/custom/path/data:/usr/src/paperless/data
  - /your/custom/path/media:/usr/src/paperless/media
  - /your/custom/path/Consume:/usr/src/paperless/consume
```

Create these directories with appropriate permissions:

```bash
mkdir -p /volume1/data_store/PaperlessStore/{data,media,Consume,db18}
sudo chown -R 1028:100 /volume1/data_store/PaperlessStore
```

### 4. Pull Docker Images

Download all required Docker images:

```bash
docker-compose pull
```

### 5. Create Initial User

Create your admin user account:

```bash
docker-compose run --rm webserver createsuperuser
```

You'll be prompted to enter:
- Username
- Email address
- Password (twice)

### 6. Start Services

Launch all containers:

```bash
docker-compose up -d
```

Check that all services are running:

```bash
docker-compose ps
```

### 7. Access Paperless

Open your web browser and navigate to:
```
http://your-nas-ip:8000
```

Log in with the credentials you created in step 5.

## Usage

### Adding Documents

There are several ways to add documents to Paperless:

#### 1. Consume Folder (Recommended)
Place documents in the consume folder:
```
/volume1/data_store/PaperlessStore/Consume
```

Paperless automatically processes files placed here and removes them after import.

#### 2. Web Upload
- Log into the web interface
- Click the "Upload" button
- Select files or drag and drop

#### 3. Email Integration
Configure email settings in Paperless to receive documents via email.

#### 4. Mobile App
Use the official Paperless-NGX mobile apps (iOS/Android) to scan and upload documents.

### Document Processing

Paperless automatically:
1. Extracts text using OCR
2. Detects document date, correspondent, and type
3. Generates thumbnails
4. Indexes content for search
5. Stores the original document

### Organizing Documents

- **Tags** - Categorize documents with multiple tags
- **Correspondents** - Track who sent/received the document
- **Document Types** - Classify documents by type (invoice, contract, etc.)
- **Custom Fields** - Add metadata specific to your needs

## Configuration

### Webhook Integration (Optional)

The default configuration includes webhook support for integration with n8n or other automation tools. To disable or modify:

Edit `docker-compose.yml`:
```yaml
environment:
  PAPERLESS_ENABLE_WEBHOOKS: True
  PAPERLESS_WEBHOOK_URLS: https://your-webhook-url
  PAPERLESS_WEBHOOK_TRIGGERS: document_added,document_updated
  PAPERLESS_WEBHOOK_AUTH_TOKEN: your-auth-token
```

To disable webhooks, remove these lines or set `PAPERLESS_ENABLE_WEBHOOKS: False`.

### OCR Language

To support multiple languages, edit `docker-compose.env`:
```env
PAPERLESS_OCR_LANGUAGE=deu+eng+fra  # German, English, French
```

### Task Workers

Adjust the number of parallel workers based on your NAS performance:
```yaml
PAPERLESS_TASK_WORKERS: 3  # Reduce to 1-2 for low-power devices
```

### Port Configuration

To change the web interface port, edit `docker-compose.yml`:
```yaml
ports:
  - "8080:8000"  # Change 8080 to your desired port
```

## Maintenance

### Backup

Use the provided backup script to create regular backups:

```bash
./scripts/backup.sh
```

This creates a compressed database backup in `/volume1/NetBackup/paperless` and automatically removes backups older than 30 days.

**To customize the backup location**, edit `scripts/backup.sh`:
```bash
BACKUP_DIR="/your/backup/path"
```

**Automate backups** using Synology Task Scheduler:
1. Open Control Panel → Task Scheduler
2. Create a new Scheduled Task → User-defined script
3. Set schedule (e.g., daily at 2 AM)
4. User: root
5. Script: `/volume1/docker/synology-paperless-compose/scripts/backup.sh`

### Database Reindexing

For performance optimization, periodically reindex the database:

```bash
./scripts/reindex.sh --container paperless-db-1
```

Options:
- `--dry-run true` - Preview without making changes
- `--min-idx-scans 5000` - Adjust threshold for reindexing
- `--concurrently false` - Disable concurrent mode for maintenance windows

### Updating

To update Paperless and all services to the latest versions:

```bash
cd /volume1/docker/synology-paperless-compose
docker-compose pull
docker-compose down
docker-compose up -d
```

**Important:** Always backup before updating!

### Logs

View logs for troubleshooting:

```bash
# All services
docker-compose logs

# Specific service
docker-compose logs webserver

# Follow logs in real-time
docker-compose logs -f webserver
```

### Database Upgrades

If upgrading PostgreSQL versions, see `upgrade_readme.md` for migration instructions.

## Troubleshooting

### Service won't start

Check logs for errors:
```bash
docker-compose logs webserver
```

Ensure all directories exist and have correct permissions:
```bash
sudo chown -R 1028:100 /volume1/data_store/PaperlessStore
```

### OCR not working

1. Verify language packages are installed (check logs)
2. Confirm `PAPERLESS_OCR_LANGUAGE` is set correctly
3. Restart services: `docker-compose restart`

### Documents not processing

1. Check consume folder permissions
2. Verify the consume folder path in `docker-compose.yml`
3. Check webserver logs: `docker-compose logs webserver`

### Performance issues

1. Reduce `PAPERLESS_TASK_WORKERS` in `docker-compose.yml`
2. Disable Tika if you don't process Office documents
3. Ensure sufficient RAM is available on your NAS

### Database connection errors

1. Check PostgreSQL is running: `docker-compose ps db`
2. Verify database credentials in configuration
3. Check database logs: `docker-compose logs db`

### Cannot access web interface

1. Verify port 8000 is not blocked by Synology firewall
2. Check if service is running: `docker-compose ps`
3. Try accessing via NAS IP: `http://nas-ip:8000`

## Security Considerations

1. **Change default credentials** - Update the secret key and admin password
2. **Use HTTPS** - Set up a reverse proxy with SSL (Synology Application Portal or Nginx Proxy Manager)
3. **Firewall** - Restrict access to port 8000 using Synology firewall rules
4. **Regular updates** - Keep Paperless and Docker images up to date
5. **Backup encryption** - Encrypt backups if they contain sensitive documents
6. **Remove webhooks** - If not needed, remove webhook configuration from `docker-compose.yml`

## Additional Resources

- [Paperless-NGX Documentation](https://docs.paperless-ngx.com/)
- [Docker Installation Guide](https://docs.paperless-ngx.com/setup/#docker_compose)
- [Paperless-NGX GitHub Repository](https://github.com/paperless-ngx/paperless-ngx)
- [Synology Docker Documentation](https://www.synology.com/en-global/dsm/packages/Docker)

## Scripts

This repository includes helpful maintenance scripts:

- **`scripts/install-paperless-ngx.sh`** - Interactive installation wizard (for standard setups)
- **`scripts/backup.sh`** - Automated database backup with rotation
- **`scripts/reindex.sh`** - PostgreSQL database reindexing for performance

## Support

For issues specific to this Synology configuration:
- Open an issue in this repository

For Paperless-NGX questions:
- Check the [official documentation](https://docs.paperless-ngx.com/)
- Visit the [Paperless-NGX discussions](https://github.com/paperless-ngx/paperless-ngx/discussions)

## License

This configuration is provided as-is for use with Paperless-NGX on Synology NAS devices. Paperless-NGX is licensed under GPLv3.
