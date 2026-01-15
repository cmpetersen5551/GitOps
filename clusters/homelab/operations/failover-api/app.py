#!/usr/bin/env python3
"""
Failover API - HTTP-triggered GitOps failover automation
Handles automated failover/failback for stateful applications with node-bound storage
"""

import os
import sys
import logging
import yaml
import json
import tempfile
import shutil
from pathlib import Path
from datetime import datetime
from typing import Dict, Tuple, Optional

from flask import Flask, jsonify, request
from git import Repo
from git.exc import GitCommandError

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s: %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Global config (loaded on startup)
SERVICES_CONFIG: Dict = {}
GIT_REPO_URL = "ssh://git@github.com/cmpetersen5551/GitOps"
REPO_PATH = "/tmp/gitops-failover"
SSH_KEY_PATH = "/run/secrets/ssh-identity"
GIT_USER = "failover-api"
GIT_EMAIL = "failover-api@cluster.local"


def load_services_config() -> bool:
    """Load services configuration from ConfigMap"""
    try:
        config_path = Path("/etc/failover-api/services.yaml")
        if not config_path.exists():
            logger.error(f"Config file not found: {config_path}")
            return False
        
        with open(config_path, 'r') as f:
            config = yaml.safe_load(f)
        
        global SERVICES_CONFIG
        SERVICES_CONFIG = config.get('services', {})
        logger.info(f"Loaded configuration for {len(SERVICES_CONFIG)} services: {list(SERVICES_CONFIG.keys())}")
        return True
    except Exception as e:
        logger.error(f"Failed to load services config: {e}")
        return False


def setup_git_repo() -> Optional[Repo]:
    """Clone or update git repository with SSH credentials"""
    try:
        # Set up SSH environment
        os.environ['GIT_SSH_COMMAND'] = f'ssh -i {SSH_KEY_PATH} -o StrictHostKeyChecking=accept-new'
        
        # Remove old repo if exists
        if Path(REPO_PATH).exists():
            shutil.rmtree(REPO_PATH)
        
        logger.info(f"Cloning repository from {GIT_REPO_URL}")
        repo = Repo.clone_from(GIT_REPO_URL, REPO_PATH)
        
        # Configure git user for commits
        repo.config_writer().set_value("user", "name", GIT_USER).release()
        repo.config_writer().set_value("user", "email", GIT_EMAIL).release()
        
        logger.info("Git repository ready")
        return repo
    except Exception as e:
        logger.error(f"Failed to setup git repository: {e}")
        return None


def get_service_config(service_name: str) -> Optional[Dict]:
    """Get configuration for a specific service"""
    if service_name not in SERVICES_CONFIG:
        logger.warning(f"Service not found in config: {service_name}")
        return None
    return SERVICES_CONFIG[service_name]


def update_deployment_manifest(
    file_path: str,
    volume_name: str,
    new_pvc: str,
    new_node_label: str,
) -> bool:
    """Update deployment manifest with new PVC and node selector"""
    try:
        with open(file_path, 'r') as f:
            manifest = yaml.safe_load(f)
        
        # Update volume to use new PVC
        spec = manifest['spec']['template']['spec']
        
        # Find and update the volume
        for volume in spec.get('volumes', []):
            if volume.get('name') == volume_name:
                volume['persistentVolumeClaim']['claimName'] = new_pvc
                logger.info(f"Updated volume '{volume_name}' to use PVC: {new_pvc}")
                break
        else:
            logger.error(f"Volume '{volume_name}' not found in deployment")
            return False
        
        # Update nodeSelector
        if 'nodeSelector' not in spec:
            spec['nodeSelector'] = {}
        spec['nodeSelector']['role'] = new_node_label
        logger.info(f"Updated nodeSelector.role to: {new_node_label}")
        
        # Write back to file
        with open(file_path, 'w') as f:
            yaml.dump(manifest, f, default_flow_style=False, sort_keys=False)
        
        return True
    except Exception as e:
        logger.error(f"Failed to update deployment manifest: {e}")
        return False


def find_deployment_path(repo: Repo, namespace: str, deployment: str) -> Optional[str]:
    """Find deployment.yaml file for given namespace and deployment"""
    try:
        # Look in apps/*/deployment.yaml or apps/*/*/deployment.yaml
        deployment_dir = Path(repo.working_dir) / "clusters/homelab/apps"
        
        # Search recursively for the deployment
        for possible_path in deployment_dir.rglob("deployment.yaml"):
            # Check if this is in the right namespace/app folder
            parent_name = possible_path.parent.name
            if parent_name == deployment:
                return str(possible_path)
        
        logger.warning(f"Deployment manifest not found for {namespace}/{deployment}")
        return None
    except Exception as e:
        logger.error(f"Error finding deployment path: {e}")
        return None


def perform_failover(
    repo: Repo,
    service_name: str,
    config: Dict,
    target_mode: str,  # 'backup' or 'primary'
    dry_run: bool = False,
) -> Tuple[bool, str]:
    """Perform failover/failback operation"""
    try:
        namespace = config['namespace']
        deployment = config['deployment']
        volume_name = config['volume_name']
        
        # Determine source and target
        if target_mode == 'backup':
            source_pvc = config['primary_pvc']
            target_pvc = config['backup_pvc']
            target_node = config['backup_node_label']
            source_node = config['primary_node_label']
        else:  # failback to primary
            source_pvc = config['backup_pvc']
            target_pvc = config['primary_pvc']
            target_node = config['primary_node_label']
            source_node = config['backup_node_label']
        
        logger.info(f"Starting {target_mode} failover for {service_name}")
        logger.info(f"  Source: {source_node}/{source_pvc} -> Target: {target_node}/{target_pvc}")
        
        # Find deployment file
        deployment_path = find_deployment_path(repo, namespace, deployment)
        if not deployment_path:
            return False, f"Deployment manifest not found for {namespace}/{deployment}"
        
        logger.info(f"Found deployment at: {deployment_path}")
        
        if dry_run:
            logger.info("[DRY RUN] Would update deployment at: " + deployment_path)
            return True, "[DRY RUN] Would perform failover (no changes made)"
        
        # Update the manifest
        if not update_deployment_manifest(
            deployment_path,
            volume_name,
            target_pvc,
            target_node,
        ):
            return False, "Failed to update deployment manifest"
        
        # Stage, commit, and push
        try:
            repo.index.add([deployment_path])
            
            timestamp = datetime.utcnow().isoformat() + 'Z'
            action = "failover to backup" if target_mode == 'backup' else "failback to primary"
            commit_msg = f"Automated {action}: {service_name} ({namespace}/{deployment})\n\n"
            commit_msg += f"Timestamp: {timestamp}\n"
            commit_msg += f"PVC: {source_pvc} -> {target_pvc}\n"
            commit_msg += f"Node: {source_node} -> {target_node}\n"
            commit_msg += f"Deployment: {deployment_path}\n"
            
            repo.index.commit(commit_msg)
            logger.info(f"Committed changes: {commit_msg[:100]}...")
            
            # Push to remote
            repo.remotes.origin.push()
            logger.info("Pushed changes to GitHub")
            
            message = f"Successfully performed {target_mode} failover for {service_name}"
            return True, message
        except GitCommandError as e:
            logger.error(f"Git operation failed: {e}")
            return False, f"Git operation failed: {str(e)}"
    
    except Exception as e:
        logger.error(f"Failover operation failed: {e}")
        return False, f"Failover failed: {str(e)}"


# ============================================================================
# Flask Routes
# ============================================================================

@app.route('/api/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'services_loaded': len(SERVICES_CONFIG),
    }), 200


@app.route('/api/services', methods=['GET'])
def list_services():
    """List all configured services"""
    services = list(SERVICES_CONFIG.keys())
    return jsonify({
        'services': services,
        'count': len(services),
    }), 200


@app.route('/api/failover/<service>/promote', methods=['POST'])
def promote(service):
    """Failover service to backup node"""
    dry_run = request.args.get('dry-run', 'false').lower() == 'true'
    
    logger.info(f"Promote request for {service} (dry_run={dry_run})")
    
    # Validate service
    config = get_service_config(service)
    if not config:
        return jsonify({'error': f'Service "{service}" not found'}), 404
    
    # Setup git repo
    repo = setup_git_repo()
    if not repo:
        return jsonify({'error': 'Failed to initialize git repository'}), 500
    
    # Perform failover
    success, message = perform_failover(repo, service, config, 'backup', dry_run=dry_run)
    
    status_code = 200 if success else 400
    return jsonify({
        'status': 'success' if success else 'error',
        'service': service,
        'action': 'promote',
        'dry_run': dry_run,
        'message': message,
    }), status_code


@app.route('/api/failover/<service>/demote', methods=['POST'])
def demote(service):
    """Failback service to primary node"""
    dry_run = request.args.get('dry-run', 'false').lower() == 'true'
    
    logger.info(f"Demote request for {service} (dry_run={dry_run})")
    
    # Validate service
    config = get_service_config(service)
    if not config:
        return jsonify({'error': f'Service "{service}" not found'}), 404
    
    # Setup git repo
    repo = setup_git_repo()
    if not repo:
        return jsonify({'error': 'Failed to initialize git repository'}), 500
    
    # Perform failback
    success, message = perform_failover(repo, service, config, 'primary', dry_run=dry_run)
    
    status_code = 200 if success else 400
    return jsonify({
        'status': 'success' if success else 'error',
        'service': service,
        'action': 'demote',
        'dry_run': dry_run,
        'message': message,
    }), status_code


@app.route('/api/failover/<service>/status', methods=['GET'])
def status(service):
    """Get current failover status for a service"""
    config = get_service_config(service)
    if not config:
        return jsonify({'error': f'Service "{service}" not found'}), 404
    
    return jsonify({
        'service': service,
        'namespace': config['namespace'],
        'deployment': config['deployment'],
        'primary_pvc': config['primary_pvc'],
        'backup_pvc': config['backup_pvc'],
        'primary_node': config['primary_node_label'],
        'backup_node': config['backup_node_label'],
        'message': 'Configuration loaded. Check deployment manifest for current active node.',
    }), 200


@app.errorhandler(404)
def not_found(error):
    return jsonify({
        'error': 'Not found',
        'message': str(error),
    }), 404


@app.errorhandler(500)
def internal_error(error):
    logger.error(f"Internal server error: {error}")
    return jsonify({
        'error': 'Internal server error',
        'message': str(error),
    }), 500


def main():
    """Application entry point"""
    # Load configuration
    if not load_services_config():
        logger.error("Failed to load services configuration")
        sys.exit(1)
    
    logger.info("Failover API starting")
    logger.info(f"Git repository: {GIT_REPO_URL}")
    logger.info(f"Services configured: {list(SERVICES_CONFIG.keys())}")
    
    # Run Flask app
    app.run(
        host='0.0.0.0',
        port=8080,
        debug=False,
        threaded=True,
    )


if __name__ == '__main__':
    main()
