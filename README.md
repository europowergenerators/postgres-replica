# Postgres replication

## Context

Odoo PSQL database = v13.1  
Frepple PSQL database = v10.22

## Setup

This repository contains compose files for PostgreSQL physical replication. Each replication stack contains
a sidecar process for SSH tunneling, and a database process for processing the replication.