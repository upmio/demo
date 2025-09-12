#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Redis Sentinel Cluster Demo Program

This program demonstrates how to use Redis + Sentinel architecture for real application development,
including session management, CRUD operations, caching functionality, and high availability testing.

Author: Auto-generated based on verify-redis-sentinel.sh
Version: 1.0
"""

import redis
import redis.sentinel
import json
import time
import uuid
import hashlib
import logging
import argparse
import sys
import os
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Any
from dataclasses import dataclass
from colorama import Fore, Back, Style, init

# Initialize colorama
init(autoreset=True)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('redis-sentinel-demo.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

@dataclass
class SentinelConfig:
    """Sentinel configuration class"""
    sentinels: List[tuple]
    master_name: str
    password: Optional[str] = None
    socket_timeout: float = 0.5
    socket_connect_timeout: float = 0.5
    
class ColorPrinter:
    """Colored output utility class"""
    
    @staticmethod
    def info(message: str):
        print(f"{Fore.BLUE}[INFO]{Style.RESET_ALL} {message}")
    
    @staticmethod
    def success(message: str):
        print(f"{Fore.GREEN}[SUCCESS]{Style.RESET_ALL} {message}")
    
    @staticmethod
    def warning(message: str):
        print(f"{Fore.YELLOW}[WARNING]{Style.RESET_ALL} {message}")
    
    @staticmethod
    def error(message: str):
        print(f"{Fore.RED}[ERROR]{Style.RESET_ALL} {message}")
    
    @staticmethod
    def step(message: str):
        print(f"{Fore.MAGENTA}[STEP]{Style.RESET_ALL} {message}")
    
    @staticmethod
    def header(message: str):
        print(f"{Fore.CYAN}{Style.BRIGHT}{message}{Style.RESET_ALL}")

class RedisSentinelManager:
    """Redis Sentinel connection manager"""
    
    def __init__(self, config: SentinelConfig):
        self.config = config
        self.sentinel = None
        self.redis_client = None
        self._connect()
    
    def _connect(self):
        """Establish Sentinel connection"""
        try:
            self.sentinel = redis.sentinel.Sentinel(
                self.config.sentinels,
                socket_timeout=self.config.socket_timeout,
                socket_connect_timeout=self.config.socket_connect_timeout
            )
            
            # Get master node connection
            self.redis_client = self.sentinel.master_for(
                self.config.master_name,
                socket_timeout=self.config.socket_timeout,
                socket_connect_timeout=self.config.socket_connect_timeout,
                password=self.config.password,
                decode_responses=True
            )
            
            # Test connection
            self.redis_client.ping()
            ColorPrinter.success("Redis Sentinel connection established successfully")
            
        except Exception as e:
            ColorPrinter.error(f"Failed to connect to Redis Sentinel: {e}")
            raise
    
    def get_master_info(self) -> Dict[str, Any]:
        """Get master node information"""
        try:
            masters = self.sentinel.sentinel_masters()
            # 确保返回值是字典类型
            if isinstance(masters, dict) and self.config.master_name in masters:
                return masters[self.config.master_name]
            elif not isinstance(masters, dict):
                ColorPrinter.warning(f"Unexpected return type from sentinel_masters: {type(masters)}, trying alternative method")
                # 尝试直接获取master信息
                try:
                    master_addr = self.sentinel.discover_master(self.config.master_name)
                    if master_addr:
                        return {
                            'ip': master_addr[0],
                            'port': master_addr[1],
                            'flags': 'master',
                            'num-slaves': 'unknown',
                            'num-other-sentinels': 'unknown'
                        }
                except Exception as inner_e:
                    ColorPrinter.warning(f"Alternative method also failed: {inner_e}")
            return {}
        except Exception as e:
            ColorPrinter.error(f"Failed to get master node information: {e}")
            return {}
    
    def get_slaves_info(self) -> List[Dict[str, Any]]:
        """Get slave nodes information"""
        try:
            result = self.sentinel.sentinel_slaves(self.config.master_name)
            # 确保返回值是列表类型
            if isinstance(result, list):
                return result
            else:
                ColorPrinter.warning(f"Unexpected return type from sentinel_slaves: {type(result)}, trying alternative method")
                # 尝试通过master连接获取复制信息
                try:
                    info = self.redis_client.info('replication')
                    slaves: List[Dict[str, Any]] = []
                    slave_count = info.get('connected_slaves', 0)
                    try:
                        slave_count = int(slave_count)
                    except Exception:
                        slave_count = 0
                    for i in range(slave_count):
                        slave_key = f'slave{i}'
                        entry = info.get(slave_key)
                        if not entry:
                            continue
                        slave_data: Dict[str, Any] = {}
                        # 兼容字符串与字典两种格式
                        if isinstance(entry, str):
                            # 解析字符串: ip=x.x.x.x,port=xxxx,state=online,offset=xxx,lag=x
                            for part in entry.split(','):
                                if '=' in part:
                                    k, v = part.split('=', 1)
                                    slave_data[k.strip()] = v.strip()
                        elif isinstance(entry, dict):
                            for k, v in entry.items():
                                slave_data[str(k)] = v
                        else:
                            # 兜底：尽最大可能提取常用字段
                            if hasattr(entry, 'get'):
                                slave_data['ip'] = entry.get('ip', 'unknown')
                                slave_data['port'] = entry.get('port', 'unknown')
                                slave_data['state'] = entry.get('state', 'unknown')
                        slaves.append({
                            'ip': str(slave_data.get('ip', 'unknown')),
                            'port': str(slave_data.get('port', 'unknown')),
                            'flags': f"slave,{slave_data.get('state', 'unknown')}"
                        })
                    return slaves
                except Exception as inner_e:
                    ColorPrinter.warning(f"Alternative method also failed: {inner_e}")
                return []
        except Exception as e:
            ColorPrinter.error(f"Failed to get slave nodes information: {e}")
            return []
    
    def get_sentinels_info(self) -> List[Dict[str, Any]]:
        """Get Sentinel nodes information"""
        try:
            result = self.sentinel.sentinel_sentinels(self.config.master_name)
            # 确保返回值是列表类型
            if isinstance(result, list):
                return result
            else:
                ColorPrinter.warning(f"Unexpected return type from sentinel_sentinels: {type(result)}, using configured sentinels")
                # 使用配置的sentinel节点信息
                sentinels = []
                for i, (host, port) in enumerate(self.config.sentinels):
                    sentinels.append({
                        'ip': host,
                        'port': str(port),
                        'flags': 'sentinel'
                    })
                return sentinels
        except Exception as e:
            ColorPrinter.error(f"Failed to get Sentinel nodes information: {e}")
            return []
    
    def test_failover(self) -> bool:
        """Test failover"""
        try:
            # Get current master node
            current_master = self.get_master_info()
            current_addr = f"{current_master.get('ip', 'unknown')}:{current_master.get('port', 'unknown')}"
            
            ColorPrinter.info(f"Current master node: {current_addr}")
            
            # Trigger failover
            result = self.sentinel.sentinel_failover(self.config.master_name)
            if result:
                ColorPrinter.info("Failover command sent successfully, waiting for completion...")
                time.sleep(5)
                
                # Check new master node
                new_master = self.get_master_info()
                new_addr = f"{new_master.get('ip', 'unknown')}:{new_master.get('port', 'unknown')}"
                
                if new_addr != current_addr:
                    ColorPrinter.success(f"Failover successful, new master node: {new_addr}")
                    return True
                else:
                    ColorPrinter.warning("Failover may not be completed or master node unchanged")
                    return False
            else:
                ColorPrinter.error("Failed to send failover command")
                return False
                
        except Exception as e:
            ColorPrinter.error(f"Failover test failed: {e}")
            return False

class SessionManager:
    """Session manager"""
    
    def __init__(self, redis_client: redis.Redis):
        self.redis_client = redis_client
        self.session_prefix = "session:"
        self.user_prefix = "user:"
        self.session_timeout = 3600  # 1 hour
    
    def create_session(self, username: str, user_data: Dict[str, Any]) -> str:
        """Create user session"""
        session_id = str(uuid.uuid4())
        session_key = f"{self.session_prefix}{session_id}"
        
        session_data = {
            "username": username,
            "created_at": datetime.now().isoformat(),
            "last_access": datetime.now().isoformat(),
            "user_data": user_data
        }
        
        try:
            self.redis_client.setex(
                session_key,
                self.session_timeout,
                json.dumps(session_data)
            )
            ColorPrinter.success(f"Session created successfully: {session_id}")
            return session_id
        except Exception as e:
            ColorPrinter.error(f"Failed to create session: {e}")
            return ""
    
    def get_session(self, session_id: str) -> Optional[Dict[str, Any]]:
        """Get session information"""
        session_key = f"{self.session_prefix}{session_id}"
        
        try:
            session_data = self.redis_client.get(session_key)
            if session_data:
                data = json.loads(session_data)
                # Update last access time
                data["last_access"] = datetime.now().isoformat()
                self.redis_client.setex(
                    session_key,
                    self.session_timeout,
                    json.dumps(data)
                )
                return data
            return None
        except Exception as e:
            ColorPrinter.error(f"Failed to get session: {e}")
            return None
    
    def delete_session(self, session_id: str) -> bool:
        """Delete session"""
        session_key = f"{self.session_prefix}{session_id}"
        
        try:
            result = self.redis_client.delete(session_key)
            if result:
                ColorPrinter.success(f"Session deleted successfully: {session_id}")
                return True
            else:
                ColorPrinter.warning(f"Session does not exist: {session_id}")
                return False
        except Exception as e:
            ColorPrinter.error(f"Failed to delete session: {e}")
            return False
    
    def list_active_sessions(self) -> List[str]:
        """List active sessions"""
        try:
            pattern = f"{self.session_prefix}*"
            keys = self.redis_client.keys(pattern)
            return [key.replace(self.session_prefix, "") for key in keys]
        except Exception as e:
            ColorPrinter.error(f"Failed to get active sessions list: {e}")
            return []

class CacheManager:
    """Cache manager"""
    
    def __init__(self, redis_client: redis.Redis):
        self.redis_client = redis_client
        self.cache_prefix = "cache:"
    
    def set_cache(self, key: str, value: Any, ttl: int = 300) -> bool:
        """Set cache"""
        cache_key = f"{self.cache_prefix}{key}"
        
        try:
            if isinstance(value, (dict, list)):
                value = json.dumps(value)
            
            result = self.redis_client.setex(cache_key, ttl, str(value))
            if result:
                ColorPrinter.success(f"Cache set successfully: {key} (TTL: {ttl}s)")
                return True
            return False
        except Exception as e:
            ColorPrinter.error(f"Failed to set cache: {e}")
            return False
    
    def get_cache(self, key: str) -> Optional[str]:
        """Get cache"""
        cache_key = f"{self.cache_prefix}{key}"
        
        try:
            value = self.redis_client.get(cache_key)
            if value:
                ttl = self.redis_client.ttl(cache_key)
                ColorPrinter.info(f"Cache hit: {key} (remaining TTL: {ttl}s)")
                return value
            else:
                ColorPrinter.info(f"Cache miss: {key}")
                return None
        except Exception as e:
            ColorPrinter.error(f"Failed to get cache: {e}")
            return None
    
    def delete_cache(self, key: str) -> bool:
        """Delete cache"""
        cache_key = f"{self.cache_prefix}{key}"
        
        try:
            result = self.redis_client.delete(cache_key)
            if result:
                ColorPrinter.success(f"Cache deleted successfully: {key}")
                return True
            else:
                ColorPrinter.warning(f"Cache does not exist: {key}")
                return False
        except Exception as e:
            ColorPrinter.error(f"Failed to delete cache: {e}")
            return False

class CounterManager:
    """Counter manager"""
    
    def __init__(self, redis_client: redis.Redis):
        self.redis_client = redis_client
        self.counter_prefix = "counter:"
    
    def increment(self, key: str, amount: int = 1) -> int:
        """Increment counter"""
        counter_key = f"{self.counter_prefix}{key}"
        
        try:
            result = self.redis_client.incrby(counter_key, amount)
            ColorPrinter.success(f"Counter {key} incremented by {amount}, current value: {result}")
            return result
        except Exception as e:
            ColorPrinter.error(f"Failed to increment counter: {e}")
            return 0
    
    def decrement(self, key: str, amount: int = 1) -> int:
        """Decrement counter"""
        counter_key = f"{self.counter_prefix}{key}"
        
        try:
            result = self.redis_client.decrby(counter_key, amount)
            ColorPrinter.success(f"Counter {key} decremented by {amount}, current value: {result}")
            return result
        except Exception as e:
            ColorPrinter.error(f"Failed to decrement counter: {e}")
            return 0
    
    def get_count(self, key: str) -> int:
        """Get counter value"""
        counter_key = f"{self.counter_prefix}{key}"
        
        try:
            result = self.redis_client.get(counter_key)
            count = int(result) if result else 0
            ColorPrinter.info(f"Counter {key} current value: {count}")
            return count
        except Exception as e:
            ColorPrinter.error(f"Failed to get counter value: {e}")
            return 0
    
    def reset_counter(self, key: str) -> bool:
        """Reset counter"""
        counter_key = f"{self.counter_prefix}{key}"
        
        try:
            result = self.redis_client.delete(counter_key)
            if result:
                ColorPrinter.success(f"Counter {key} reset successfully")
                return True
            else:
                ColorPrinter.warning(f"Counter {key} does not exist")
                return False
        except Exception as e:
            ColorPrinter.error(f"Failed to reset counter: {e}")
            return False

class RedisSentinelDemo:
    """Redis Sentinel Demo Program"""
    
    def __init__(self):
        # Initialize components
        self.sentinel_manager = None
        self.session_manager = None
        self.cache_manager = None
        self.counter_manager = None
        self.current_session_id = None
    
    def setup_connection(self):
        """Setup connection configuration"""
        ColorPrinter.header("Redis Sentinel Connection Configuration")
        ColorPrinter.header("=" * 50)
        
        # Get Sentinel node configuration
        sentinels = []
        ColorPrinter.info("Please enter Sentinel node information (at least one node):")
        
        while True:
            host = input("Sentinel host address (press Enter to finish): ").strip()
            if not host:
                break
            
            try:
                port = int(input("Sentinel port (default 26379): ") or "26379")
                sentinels.append((host, port))
                ColorPrinter.success(f"Added Sentinel node: {host}:{port}")
            except ValueError:
                ColorPrinter.error("Port must be a number")
        
        if not sentinels:
            ColorPrinter.error("At least one Sentinel node is required")
            return False
        
        # Get other configuration
        master_name = input("Master node name (default mymaster): ").strip() or "mymaster"
        password = input("Redis password (optional): ").strip() or None
        
        # Create configuration and connect
        try:
            config = SentinelConfig(
                sentinels=sentinels,
                master_name=master_name,
                password=password
            )
            
            self.sentinel_manager = RedisSentinelManager(config)
            
            # Initialize managers
            redis_client = self.sentinel_manager.redis_client
            self.session_manager = SessionManager(redis_client)
            self.cache_manager = CacheManager(redis_client)
            self.counter_manager = CounterManager(redis_client)
            
            return True
            
        except Exception as e:
            ColorPrinter.error(f"Connection failed: {e}")
            return False
    
    def show_cluster_info(self):
        """Show cluster information"""
        ColorPrinter.step("Getting cluster information...")
        
        # Master node information
        master_info = self.sentinel_manager.get_master_info()
        if master_info:
            ColorPrinter.success("Master node information:")
            print(f"  Address: {master_info.get('ip', 'N/A')}:{master_info.get('port', 'N/A')}")
            print(f"  Status: {master_info.get('flags', 'N/A')}")
            print(f"  Slave count: {master_info.get('num-slaves', 'N/A')}")
            print(f"  Sentinel count: {master_info.get('num-other-sentinels', 'N/A')}")
        
        # Slave node information
        slaves_info = self.sentinel_manager.get_slaves_info()
        if slaves_info and isinstance(slaves_info, list):
            ColorPrinter.success(f"Slave node information ({len(slaves_info)} nodes):")
            for i, slave in enumerate(slaves_info, 1):
                print(f"  Slave{i}: {slave.get('ip', 'N/A')}:{slave.get('port', 'N/A')} ({slave.get('flags', 'N/A')})")
        elif slaves_info:
            ColorPrinter.warning("Slave node information: Unable to retrieve (connection issue)")
        else:
            ColorPrinter.info("Slave node information: No slave nodes found")
        
        # Sentinel node information
        sentinels_info = self.sentinel_manager.get_sentinels_info()
        if sentinels_info and isinstance(sentinels_info, list):
            ColorPrinter.success(f"Sentinel node information ({len(sentinels_info)} nodes):")
            for i, sentinel in enumerate(sentinels_info, 1):
                print(f"  Sentinel{i}: {sentinel.get('ip', 'N/A')}:{sentinel.get('port', 'N/A')}")
        elif sentinels_info:
            ColorPrinter.warning("Sentinel node information: Unable to retrieve (connection issue)")
        else:
            ColorPrinter.info("Sentinel node information: No sentinel nodes found")
    
    def demo_session_management(self):
        """Session management demo"""
        ColorPrinter.step("Session Management Demo")
        
        while True:
            print("\nSession Management Options:")
            print("1. Create Session")
            print("2. View Current Session")
            print("3. List All Active Sessions")
            print("4. Delete Session")
            print("0. Return to Main Menu")
            
            choice = input("Please select operation: ").strip()
            
            if choice == "1":
                username = input("Username: ").strip()
                if username:
                    user_data = {
                        "email": input("Email (optional): ").strip(),
                        "role": input("Role (optional): ").strip() or "user",
                        "login_ip": "127.0.0.1"
                    }
                    session_id = self.session_manager.create_session(username, user_data)
                    if session_id:
                        self.current_session_id = session_id
                        ColorPrinter.info(f"Current session ID: {session_id}")
            
            elif choice == "2":
                if self.current_session_id:
                    session_data = self.session_manager.get_session(self.current_session_id)
                    if session_data:
                        ColorPrinter.success("Current session information:")
                        print(json.dumps(session_data, indent=2, ensure_ascii=False))
                    else:
                        ColorPrinter.warning("Session expired or does not exist")
                        self.current_session_id = None
                else:
                    ColorPrinter.warning("No active session")
            
            elif choice == "3":
                sessions = self.session_manager.list_active_sessions()
                if sessions:
                    ColorPrinter.success(f"Active sessions ({len(sessions)} sessions):")
                    for session_id in sessions:
                        print(f"  - {session_id}")
                else:
                    ColorPrinter.info("No active sessions")
            
            elif choice == "4":
                session_id = input("Session ID to delete (press Enter to delete current session): ").strip()
                if not session_id and self.current_session_id:
                    session_id = self.current_session_id
                
                if session_id:
                    if self.session_manager.delete_session(session_id):
                        if session_id == self.current_session_id:
                            self.current_session_id = None
                else:
                    ColorPrinter.warning("Please provide a valid session ID")
            
            elif choice == "0":
                break
            
            else:
                ColorPrinter.warning("Invalid selection")
    
    def demo_crud_operations(self):
        """CRUD Operations Demo"""
        ColorPrinter.step("CRUD Operations Demo")
        
        while True:
            print("\nCRUD Operation Options:")
            print("1. Create/Update Key-Value")
            print("2. Read Key-Value")
            print("3. Delete Key")
            print("4. Batch Operations")
            print("5. List All Keys")
            print("0. Return to Main Menu")
            
            choice = input("Please select operation: ").strip()
            
            if choice == "1":
                key = input("Key name: ").strip()
                value = input("Value: ").strip()
                ttl = input("TTL (seconds, optional): ").strip()
                
                if key and value:
                    try:
                        if ttl:
                            self.sentinel_manager.redis_client.setex(key, int(ttl), value)
                            ColorPrinter.success(f"Key '{key}' set successfully, TTL: {ttl}s")
                        else:
                            self.sentinel_manager.redis_client.set(key, value)
                            ColorPrinter.success(f"Key '{key}' set successfully")
                    except Exception as e:
                        ColorPrinter.error(f"Set failed: {e}")
            
            elif choice == "2":
                key = input("Key name: ").strip()
                if key:
                    try:
                        value = self.sentinel_manager.redis_client.get(key)
                        if value:
                            ttl = self.sentinel_manager.redis_client.ttl(key)
                            ColorPrinter.success(f"Key '{key}' value: {value}")
                            if ttl > 0:
                                ColorPrinter.info(f"Remaining TTL: {ttl}s")
                        else:
                            ColorPrinter.warning(f"Key '{key}' does not exist")
                    except Exception as e:
                        ColorPrinter.error(f"Read failed: {e}")
            
            elif choice == "3":
                key = input("键名: ").strip()
                if key:
                    try:
                        result = self.sentinel_manager.redis_client.delete(key)
                        if result:
                            ColorPrinter.success(f"Key '{key}' deleted successfully")
                        else:
                            ColorPrinter.warning(f"Key '{key}' does not exist")
                    except Exception as e:
                        ColorPrinter.error(f"Delete failed: {e}")
            
            elif choice == "4":
                print("Batch Operations Demo:")
                # Batch set
                batch_data = {
                    "user:1001": "Alice",
                    "user:1002": "Bob",
                    "user:1003": "Charlie"
                }
                
                try:
                    pipe = self.sentinel_manager.redis_client.pipeline()
                    for k, v in batch_data.items():
                        pipe.set(k, v)
                    results = pipe.execute()
                    ColorPrinter.success(f"Batch set completed: {len(results)} keys")
                    
                    # Batch get
                    values = self.sentinel_manager.redis_client.mget(list(batch_data.keys()))
                    ColorPrinter.success("Batch get results:")
                    for k, v in zip(batch_data.keys(), values):
                        print(f"  {k}: {v}")
                        
                except Exception as e:
                    ColorPrinter.error(f"Batch operation failed: {e}")
            
            elif choice == "5":
                pattern = input("Key pattern (default *): ").strip() or "*"
                try:
                    keys = self.sentinel_manager.redis_client.keys(pattern)
                    if keys:
                        ColorPrinter.success(f"Matching keys ({len(keys)} keys):")
                        for key in sorted(keys):
                            print(f"  - {key}")
                    else:
                        ColorPrinter.info("No matching keys")
                except Exception as e:
                    ColorPrinter.error(f"Failed to get key list: {e}")
            
            elif choice == "0":
                break
            
            else:
                ColorPrinter.warning("Invalid selection")
    
    def demo_cache_operations(self):
        """Cache operations demo"""
        ColorPrinter.step("Cache Operations Demo")
        
        while True:
            print("\nCache Operation Options:")
            print("1. Set Cache")
            print("2. Get Cache")
            print("3. Delete Cache")
            print("4. Simulate Database Query Cache")
            print("0. Return to Main Menu")
            
            choice = input("Please select operation: ").strip()
            
            if choice == "1":
                key = input("Cache key: ").strip()
                value = input("Cache value: ").strip()
                ttl = input("TTL (seconds, default 300): ").strip()
                
                if key and value:
                    ttl = int(ttl) if ttl else 300
                    self.cache_manager.set_cache(key, value, ttl)
            
            elif choice == "2":
                key = input("Cache key: ").strip()
                if key:
                    value = self.cache_manager.get_cache(key)
                    if value:
                        print(f"Cache value: {value}")
            
            elif choice == "3":
                key = input("Cache key: ").strip()
                if key:
                    self.cache_manager.delete_cache(key)
            
            elif choice == "4":
                # Simulate database query cache scenario
                user_id = input("User ID: ").strip()
                if user_id:
                    cache_key = f"user_profile_{user_id}"
                    
                    # Try to get from cache first
                    cached_data = self.cache_manager.get_cache(cache_key)
                    
                    if cached_data:
                        ColorPrinter.success("Retrieved user info from cache")
                        print(f"User info: {cached_data}")
                    else:
                        # Simulate database query
                        ColorPrinter.info("Cache miss, simulating database query...")
                        time.sleep(1)  # Simulate query delay
                        
                        # Simulate query result
                        user_data = {
                            "id": user_id,
                            "name": f"User_{user_id}",
                            "email": f"user{user_id}@example.com",
                            "created_at": datetime.now().isoformat()
                        }
                        
                        # Store in cache
                        self.cache_manager.set_cache(cache_key, json.dumps(user_data), 600)
                        ColorPrinter.success("Query result cached")
                        print(f"User info: {json.dumps(user_data, indent=2, ensure_ascii=False)}")
            
            elif choice == "0":
                break
            
            else:
                ColorPrinter.warning("Invalid selection")
    
    def demo_counter_operations(self):
        """Counter operations demo"""
        ColorPrinter.step("Counter Operations Demo")
        
        while True:
            print("\nCounter Operation Options:")
            print("1. Increment Counter")
            print("2. Decrement Counter")
            print("3. Get Counter Value")
            print("4. Reset Counter")
            print("5. Simulate Website Visit Statistics")
            print("0. Return to Main Menu")
            
            choice = input("Please select operation: ").strip()
            
            if choice == "1":
                key = input("Counter name: ").strip()
                amount = input("Increment amount (default 1): ").strip()
                
                if key:
                    amount = int(amount) if amount else 1
                    self.counter_manager.increment(key, amount)
            
            elif choice == "2":
                key = input("Counter name: ").strip()
                amount = input("Decrement amount (default 1): ").strip()
                
                if key:
                    amount = int(amount) if amount else 1
                    self.counter_manager.decrement(key, amount)
            
            elif choice == "3":
                key = input("Counter name: ").strip()
                if key:
                    self.counter_manager.get_count(key)
            
            elif choice == "4":
                key = input("Counter name: ").strip()
                if key:
                    self.counter_manager.reset_counter(key)
            
            elif choice == "5":
                # Simulate website visit statistics
                ColorPrinter.info("Simulating website visit statistics...")
                
                pages = ["home", "about", "products", "contact"]
                
                for _ in range(10):
                    page = pages[int(time.time() * 1000) % len(pages)]
                    self.counter_manager.increment(f"page_views_{page}")
                    time.sleep(0.1)
                
                ColorPrinter.success("Visit statistics completed, viewing results:")
                for page in pages:
                    count = self.counter_manager.get_count(f"page_views_{page}")
                    print(f"  {page} page views: {count}")
            
            elif choice == "0":
                break
            
            else:
                ColorPrinter.warning("Invalid selection")
    
    def demo_high_availability(self):
        """High availability demo"""
        ColorPrinter.step("High Availability Test")
        
        while True:
            print("\nHigh Availability Test Options:")
            print("1. Connection Status Test")
            print("2. Failover Test")
            print("3. Read-Write Consistency Test")
            print("4. Performance Stress Test")
            print("0. Return to Main Menu")
            
            choice = input("Please select operation: ").strip()
            
            if choice == "1":
                try:
                    # 测试Redis连接
                    result = self.sentinel_manager.redis_client.ping()
                    if result:
                        ColorPrinter.success("Redis connection normal")
                    
                    # Test Sentinel connection
                    masters = self.sentinel_manager.sentinel.sentinel_masters()
                    # 兼容不同返回类型，避免因bool类型导致len()报错
                    masters_count_str = "unknown"
                    if isinstance(masters, dict):
                        masters_count_str = str(len(masters))
                    elif isinstance(masters, list):
                        masters_count_str = str(len(masters))
                    elif isinstance(masters, bool):
                        # 某些环境会返回bool，无法统计数量，尝试探测master地址以验证连通性
                        try:
                            addr = self.sentinel_manager.sentinel.discover_master(self.sentinel_manager.config.master_name)
                            if addr and isinstance(addr, (list, tuple)):
                                masters_count_str = "1"
                        except Exception:
                            masters_count_str = "unknown"
                    # 只要调用成功即认为连通，数量未知时以unknown展示
                    ColorPrinter.success(f"Sentinel connection normal, monitoring {masters_count_str} master nodes")
                    
                    # Show current master node
                    master_info = self.sentinel_manager.get_master_info()
                    if master_info:
                        ColorPrinter.info(f"Current master node: {master_info.get('ip')}:{master_info.get('port')}")
                        
                except Exception as e:
                    ColorPrinter.error(f"Connection test failed: {e}")
            
            elif choice == "2":
                ColorPrinter.warning("Failover test will cause brief service interruption")
                confirm = input("Confirm failover test execution? (y/N): ").strip().lower()
                
                if confirm == 'y':
                    success = self.sentinel_manager.test_failover()
                    if success:
                        ColorPrinter.success("Failover test completed")
                        # Reconnect to ensure using new master node
                        try:
                            self.sentinel_manager._connect()
                            ColorPrinter.success("Reconnected to new master node")
                        except Exception as e:
                            ColorPrinter.error(f"Reconnection failed: {e}")
                    else:
                        ColorPrinter.error("Failover test failed")
                else:
                    ColorPrinter.info("Failover test cancelled")
            
            elif choice == "3":
                ColorPrinter.info("Executing read-write consistency test...")
                
                test_key = f"consistency_test_{int(time.time())}"
                test_value = f"test_value_{uuid.uuid4().hex[:8]}"
                
                try:
                    # Write data
                    self.sentinel_manager.redis_client.set(test_key, test_value)
                    ColorPrinter.success(f"Written test data: {test_key} = {test_value}")
                    
                    # Read immediately
                    read_value = self.sentinel_manager.redis_client.get(test_key)
                    
                    if read_value == test_value:
                        ColorPrinter.success("Read-write consistency test passed")
                    else:
                        ColorPrinter.error(f"Read-write consistency test failed: expected {test_value}, actual {read_value}")
                    
                    # Clean up test data
                    self.sentinel_manager.redis_client.delete(test_key)
                    
                except Exception as e:
                    ColorPrinter.error(f"Read-write consistency test failed: {e}")
            
            elif choice == "4":
                ColorPrinter.info("Executing performance stress test...")
                
                operations = int(input("Number of test operations (default 1000): ") or "1000")
                
                start_time = time.time()
                success_count = 0
                error_count = 0
                
                try:
                    pipe = self.sentinel_manager.redis_client.pipeline()
                    
                    for i in range(operations):
                        key = f"perf_test_{i}"
                        value = f"value_{i}_{uuid.uuid4().hex[:8]}"
                        pipe.set(key, value)
                        
                        if (i + 1) % 100 == 0:
                            try:
                                pipe.execute()
                                success_count += 100
                                pipe = self.sentinel_manager.redis_client.pipeline()
                            except Exception as e:
                                error_count += 100
                                ColorPrinter.error(f"Batch execution failed: {e}")
                                pipe = self.sentinel_manager.redis_client.pipeline()
                    
                    # Execute remaining operations
                    if operations % 100 != 0:
                        try:
                            pipe.execute()
                            success_count += operations % 100
                        except Exception as e:
                            error_count += operations % 100
                            ColorPrinter.error(f"Final batch execution failed: {e}")
                    
                    end_time = time.time()
                    duration = end_time - start_time
                    
                    ColorPrinter.success(f"Performance test completed:")
                    print(f"  Total operations: {operations}")
                    print(f"  Successful operations: {success_count}")
                    print(f"  Failed operations: {error_count}")
                    print(f"  Total time: {duration:.2f}s")
                    print(f"  Average QPS: {operations/duration:.2f}")
                    
                    # Clean up test data
                    ColorPrinter.info("Cleaning up test data...")
                    test_keys = [f"perf_test_{i}" for i in range(operations)]
                    deleted = self.sentinel_manager.redis_client.delete(*test_keys)
                    ColorPrinter.success(f"Cleanup completed, deleted {deleted} keys")
                    
                except Exception as e:
                    ColorPrinter.error(f"Performance test failed: {e}")
            
            elif choice == "0":
                break
            
            else:
                ColorPrinter.warning("Invalid selection")
    
    def show_main_menu(self):
        """Show main menu"""
        ColorPrinter.header("\nRedis Sentinel Demo Program")
        ColorPrinter.header("=" * 50)
        print("1. Show Cluster Information")
        print("2. Session Management Demo")
        print("3. CRUD Operations Demo")
        print("4. Cache Operations Demo")
        print("5. Counter Operations Demo")
        print("6. High Availability Test")
        print("0. Exit Program")
        print("=" * 50)
    
    def run(self):
        """Run demo program"""
        ColorPrinter.header("Redis Sentinel Cluster Demo Program")
        ColorPrinter.header("=" * 60)
        
        # Setup connection
        if not self.setup_connection():
            ColorPrinter.error("Connection setup failed, program exiting")
            return
        
        # Show cluster information
        self.show_cluster_info()
        
        # Main loop
        while True:
            try:
                self.show_main_menu()
                choice = input("Please select operation: ").strip()
                
                if choice == "1":
                    self.show_cluster_info()
                elif choice == "2":
                    self.demo_session_management()
                elif choice == "3":
                    self.demo_crud_operations()
                elif choice == "4":
                    self.demo_cache_operations()
                elif choice == "5":
                    self.demo_counter_operations()
                elif choice == "6":
                    self.demo_high_availability()
                elif choice == "0":
                    ColorPrinter.success("Thank you for using Redis Sentinel Demo Program!")
                    break
                else:
                    ColorPrinter.warning("Invalid selection, please try again")
                    
            except KeyboardInterrupt:
                ColorPrinter.warning("\nProgram interrupted by user")
                break
            except Exception as e:
                ColorPrinter.error(f"Program error: {e}")
                logger.exception("Program exception")

def main():
    """Main function"""
    parser = argparse.ArgumentParser(description="Redis Sentinel Cluster Demo Program")
    parser.add_argument("--config", help="Configuration file path")
    parser.add_argument("--log-level", choices=["DEBUG", "INFO", "WARNING", "ERROR"], 
                       default="INFO", help="Log level")
    
    args = parser.parse_args()
    
    # Set log level
    logging.getLogger().setLevel(getattr(logging, args.log_level))
    
    try:
        demo = RedisSentinelDemo()
        demo.run()
    except Exception as e:
        ColorPrinter.error(f"Program startup failed: {e}")
        logger.exception("Program startup exception")
        sys.exit(1)

if __name__ == "__main__":
    main()
