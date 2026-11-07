// Generated from compose-go v2.16.2, the version Docker Compose v5.7.0 uses: each case's
// files loaded with `loader.LoadWithContext`, as `docker compose -f ... -f ...` loads them.
enum ComposeMergeGolden {
    static let cases: [(name: String, files: [String], merged: String)] = [
        ("a second file adds a volume, a port and a dependency", [
            #"""
services:
  opensearch:
    image: opensearchproject/opensearch:2.19.1
    entrypoint: ["/setup/entrypoint.sh"]
    ports:
      - "9200:9200"
    volumes:
      - ./opensearch:/setup
      - data:/usr/share/opensearch/data
    depends_on:
      - init
  init:
    image: alpine:3.20
  dashboards:
    image: opensearchproject/opensearch-dashboards:2.19.1
volumes:
  data: {}
"""#,
            #"""
services:
  opensearch:
    ports:
      - "9600:9600"
    volumes:
      - ./plugins:/usr/share/opensearch/plugins
    depends_on:
      - dashboards
"""#,
        ], #"""
dashboards
  image: opensearchproject/opensearch-dashboards:2.19.1
  networks: default()
init
  image: alpine:3.20
  networks: default()
opensearch
  image: opensearchproject/opensearch:2.19.1
  entrypoint: /setup/entrypoint.sh
  ports: :9200:9200/tcp | :9600:9600/tcp
  volumes: ./opensearch:/setup | data:/usr/share/opensearch/data | ./plugins:/usr/share/opensearch/plugins
  networks: default()
  depends_on: dashboards=service_started | init=service_started
"""#),
        ("volumes are merged by target", [
            #"""
services:
  app:
    image: alpine:3.20
    volumes:
      - data:/data
      - ./conf:/etc/app:ro
      - /cache
      - ./logs:/var/log/app
volumes:
  data: {}
  other: {}
"""#,
            #"""
services:
  app:
    volumes:
      - other:/data/
      - ./conf:/etc/app:ro
      - ./cache:/cache
      - ./tmp:/tmp
"""#,
        ], #"""
app
  image: alpine:3.20
  volumes: other:/data | ./conf:/etc/app:ro | ./cache:/cache | ./logs:/var/log/app | ./tmp:/tmp
  networks: default()
"""#),
        ("ports are merged by host IP, published port, target and protocol", [
            #"""
services:
  web:
    image: nginx:1.27
    ports:
      - "8080:80"
      - "127.0.0.1:9090:90"
      - "53:53/udp"
      - "3000:3000"
      - "4000"
      - "127.0.0.1::5000"
"""#,
            #"""
services:
  web:
    ports:
      - "0.0.0.0:8080:80"
      - "9090:90"
      - "53:53/udp"
      - "53:53"
      - "3001:3000"
      - "4000"
      - "443"
      - "127.0.0.1::5000"
"""#,
        ], #"""
web
  image: nginx:1.27
  ports: 0.0.0.0:8080:80/tcp | 127.0.0.1:9090:90/tcp | :53:53/udp | :3000:3000/tcp | ::4000/tcp | 127.0.0.1::5000/tcp | :9090:90/tcp | :53:53/tcp | :3001:3000/tcp | ::443/tcp
  networks: default()
"""#),
        ("depends_on is merged as a mapping, and the short form resets the condition", [
            #"""
services:
  db:
    image: postgres:16
  cache:
    image: valkey/valkey:8
  migrate:
    image: alpine:3.20
  queue:
    image: rabbitmq:4
  short:
    image: alpine:3.20
    depends_on:
      db:
        condition: service_healthy
      cache:
        condition: service_started
      migrate:
        condition: service_completed_successfully
  long:
    image: alpine:3.20
    depends_on:
      - db
  unconditioned:
    image: alpine:3.20
    depends_on:
      db:
        condition: service_healthy
"""#,
            #"""
services:
  short:
    depends_on:
      - db
      - queue
  long:
    depends_on:
      db:
        condition: service_healthy
      migrate:
        condition: service_completed_successfully
  unconditioned:
    depends_on:
      db:
        restart: true
"""#,
        ], #"""
cache
  image: valkey/valkey:8
  networks: default()
db
  image: postgres:16
  networks: default()
long
  image: alpine:3.20
  networks: default()
  depends_on: db=service_healthy | migrate=service_completed_successfully
migrate
  image: alpine:3.20
  networks: default()
queue
  image: rabbitmq:4
  networks: default()
short
  image: alpine:3.20
  networks: default()
  depends_on: cache=service_started | db=service_started | migrate=service_completed_successfully | queue=service_started
unconditioned
  image: alpine:3.20
  networks: default()
  depends_on: db=service_healthy
"""#),
        ("networks are merged as a mapping, aliases appended", [
            #"""
services:
  web:
    image: nginx:1.27
    networks:
      - front
  api:
    image: alpine:3.20
    networks:
      back:
        aliases: [api, backend]
  worker:
    image: alpine:3.20
  admin:
    image: alpine:3.20
    networks:
      back:
        aliases: [admin]
networks:
  front: {}
  back: {}
"""#,
            #"""
services:
  web:
    networks:
      back:
        aliases: [web]
      front:
        aliases: [www]
  api:
    networks:
      back:
        aliases: [svc, api]
  worker:
    networks:
      - back
  admin:
    networks:
      - back
      - front
"""#,
        ], #"""
admin
  image: alpine:3.20
  networks: back(admin) | front()
api
  image: alpine:3.20
  networks: back(api,backend,svc)
web
  image: nginx:1.27
  networks: back(web) | front(www)
worker
  image: alpine:3.20
  networks: back()
"""#),
        ("configs and secrets are merged by target", [
            #"""
services:
  app:
    image: alpine:3.20
    configs:
      - a
      - source: b
        target: /etc/b
    secrets:
      - s1
      - source: s2
        target: /run/secrets/custom
configs:
  a:
    content: a
  b:
    content: b
  c:
    content: c
secrets:
  s1:
    file: ./s1.txt
  s2:
    file: ./s2.txt
  s3:
    file: ./s3.txt
"""#,
            #"""
services:
  app:
    configs:
      - source: a
        target: /a
        mode: "0440"
      - source: c
        target: /etc/b
      - c
    secrets:
      - source: s1
        mode: "0400"
      - s3
      - source: s2
        target: custom
"""#,
        ], #"""
app
  image: alpine:3.20
  networks: default()
  configs: a:/a:440 | c:/etc/b:- | c::-
  secrets: s1:/run/secrets/s1:400 | s2:/run/secrets/custom:- | s3:/run/secrets/s3:- | s2:custom:-
"""#),
        ("profiles and tmpfs are appended without duplicates", [
            #"""
services:
  tool:
    image: alpine:3.20
    profiles: [debug]
    tmpfs:
      - /run:size=64m
      - /tmp
  string:
    image: alpine:3.20
    tmpfs: /run
"""#,
            #"""
services:
  tool:
    profiles: [tools, debug]
    tmpfs:
      - /run:size=128m
      - /tmp
      - /cache
  string:
    tmpfs: /tmp
"""#,
        ], #"""
string
  image: alpine:3.20
  networks: default()
  tmpfs: /run | /tmp
tool
  image: alpine:3.20
  networks: default()
  profiles: debug | tools
  tmpfs: /run:size=128m | /tmp | /cache
"""#),
        ("healthcheck fields are merged, test is overridden", [
            #"""
services:
  db:
    image: postgres:16
    healthcheck:
      test: ["CMD", "pg_isready"]
      interval: 5s
      retries: 10
  cache:
    image: valkey/valkey:8
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      timeout: 2s
  disabled:
    image: alpine:3.20
    healthcheck:
      disable: true
  enabled:
    image: alpine:3.20
    healthcheck:
      test: ["CMD", "true"]
  untouched:
    image: alpine:3.20
    healthcheck:
      test: ["CMD", "true"]
      interval: 1s
"""#,
            #"""
services:
  db:
    healthcheck:
      interval: 1s
      start_period: 10s
  cache:
    healthcheck:
      test: valkey-cli ping
  disabled:
    healthcheck:
      test: ["CMD", "true"]
  enabled:
    healthcheck:
      disable: true
  untouched:
    image: alpine:3.21
"""#,
        ], #"""
cache
  image: valkey/valkey:8
  networks: default()
  healthcheck: test=[sh -c valkey-cli ping] interval=30 timeout=2 retries=3 start_period=0
db
  image: postgres:16
  networks: default()
  healthcheck: test=[pg_isready] interval=1 timeout=30 retries=10 start_period=10
disabled
  image: alpine:3.20
  networks: default()
  healthcheck: test=[] interval=30 timeout=30 retries=3 start_period=0
enabled
  image: alpine:3.20
  networks: default()
  healthcheck: test=[] interval=30 timeout=30 retries=3 start_period=0
untouched
  image: alpine:3.21
  networks: default()
  healthcheck: test=[true] interval=1 timeout=30 retries=3 start_period=0
"""#),
        ("build fields are merged, args by key", [
            #"""
services:
  app:
    build:
      context: ./app
      dockerfile: Dockerfile.dev
      args:
        A: "1"
        B: "1"
  web:
    build: ./web
  api:
    build:
      context: ./api
      target: prod
  worker:
    image: worker:latest
"""#,
            #"""
services:
  app:
    build:
      target: dev
      args:
        - B=2
        - C=3
  web:
    build:
      dockerfile: Dockerfile.web
  api:
    build: ./api2
  worker:
    build:
      context: ./worker
"""#,
        ], #"""
api
  build: context=./api2 dockerfile=Dockerfile target=prod args=[]
  networks: default()
app
  build: context=./app dockerfile=Dockerfile.dev target=dev args=[A=1 B=2 C=3]
  networks: default()
web
  build: context=./web dockerfile=Dockerfile.web target=- args=[]
  networks: default()
worker
  image: worker:latest
  build: context=./worker dockerfile=Dockerfile target=- args=[]
  networks: default()
"""#),
        ("command and entrypoint are overridden, environment and labels merged by key", [
            #"""
services:
  app:
    image: alpine:3.20
    command: ["sleep", "60"]
    entrypoint: ["/bin/sh", "-c"]
    environment:
      A: "1"
      B: "1"
    labels:
      x: "1"
  other:
    image: alpine:3.20
    command: ["echo", "hi"]
"""#,
            #"""
services:
  app:
    image: alpine:3.21
    command: ["sleep", "120"]
    environment:
      - B=2
      - C=3
    labels:
      y: "2"
  extra:
    image: busybox:1.37
    ports:
      - "8000:8000"
"""#,
        ], #"""
app
  image: alpine:3.21
  command: sleep | 120
  entrypoint: /bin/sh | -c
  environment: A=1 | B=2 | C=3
  labels: x=1 | y=2
  networks: default()
extra
  image: busybox:1.37
  ports: :8000:8000/tcp
  networks: default()
other
  image: alpine:3.20
  command: echo | hi
  networks: default()
"""#),
        ("three files merge in order", [
            #"""
services:
  app:
    image: alpine:3.20
    ports:
      - "8080:80"
    volumes:
      - ./one:/one
    profiles: [a]
    networks: [front]
networks:
  front: {}
  back: {}
"""#,
            #"""
services:
  app:
    ports:
      - "8081:81"
    volumes:
      - ./two:/two
      - ./one:/one
    profiles: [b]
    networks:
      back:
        aliases: [x]
"""#,
            #"""
services:
  app:
    ports:
      - "8080:80"
      - "8082:82"
    volumes:
      - ./three:/one
    profiles: [a, c]
    networks:
      back:
        aliases: [y, x]
"""#,
        ], #"""
app
  image: alpine:3.20
  ports: :8080:80/tcp | :8081:81/tcp | :8082:82/tcp
  volumes: ./three:/one | ./two:/two
  networks: back(x,y) | front()
  profiles: a | b | c
"""#),
    ]
}
