# Awesant::Output::Redis

## Description

This transport module connects to a Redis database and ships data via RPUSH.

## Options

### host

The hostname or ip address of the Redis server.

Default: 127.0.0.1

### port

The port number where the Redis server is listen on.

Default: 6379

### timeout

The timeout in seconds to connect and transport data to the Redis server.

Default: 10

### database

The database to select.

Default: 0

### password

The password to use for authentication.

Default: not set

### key 

The key is mandatory and is used to transport the data. This key is necessary for logstash to pull the data from the Redis database.

Default: not set

### bulk

The number of lines to attempt to send to Redis at once.

May help to increase in high latency environments with high log throughput.

Default: 1

