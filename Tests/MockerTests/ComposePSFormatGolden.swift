// Generated from Docker Compose v5.7.0 and Docker CLI v29.9.3 formatting code, run on the same
// containers with TZ=Europe/Istanbul.
enum ComposePSFormatGolden {
    static let cases: [(fixture: String, format: String, noTrunc: Bool, output: String)] = [
        ("stack", #""#, false, #"""
NAME                             IMAGE                                                                  COMMAND                   SERVICE     CREATED              STATUS    PORTS
gdprapi-2564206480-builder-1     golang:1.26.10-alpine3.23                                              "go build -ldflags -…"    builder     25 seconds ago       Exited    
gdprapi-2564206480-gdprapi-1     golang:1.26.10-alpine3.23                                              "/gdprapi -config /g…"    gdprapi     22 seconds ago       Up        127.0.0.1:65389->8080/tcp
gdprapi-2564206480-snowflake-1   677516718998.dkr.ecr.us-east-1.amazonaws.com/bigdata/fakesnow:v0.1.0   "python /snowflake/s…"    snowflake   About a minute ago   Up        
zeta-web-1                       nginx:1.27                                                             "sh -c \"echo <hi> &&…"   web         2 days ago           Exited    0.0.0.0:8080-8081->8080-8081/tcp, [::]:8080->8080/tcp, 9000/udp
"""#),
        ("stack", #"table"#, false, #"""
NAME                             IMAGE                                                                  COMMAND                   SERVICE     CREATED              STATUS    PORTS
gdprapi-2564206480-builder-1     golang:1.26.10-alpine3.23                                              "go build -ldflags -…"    builder     25 seconds ago       Exited    
gdprapi-2564206480-gdprapi-1     golang:1.26.10-alpine3.23                                              "/gdprapi -config /g…"    gdprapi     22 seconds ago       Up        127.0.0.1:65389->8080/tcp
gdprapi-2564206480-snowflake-1   677516718998.dkr.ecr.us-east-1.amazonaws.com/bigdata/fakesnow:v0.1.0   "python /snowflake/s…"    snowflake   About a minute ago   Up        
zeta-web-1                       nginx:1.27                                                             "sh -c \"echo <hi> &&…"   web         2 days ago           Exited    0.0.0.0:8080-8081->8080-8081/tcp, [::]:8080->8080/tcp, 9000/udp
"""#),
        ("stack", #"json"#, false, #"""
{"Command":"\"go build -ldflags -…\"","CreatedAt":"2026-11-05 14:42:55 +0300 +03","Engine":"","ExitCode":0,"Health":"","ID":"gdprapi-2564","Image":"golang:1.26.10-alpine3.23","Labels":"","LocalVolumes":"0","Mounts":"","Name":"gdprapi-2564206480-builder-1","Names":"gdprapi-2564206480-builder-1","Networks":"","Ports":"","Project":"gdprapi-2564206480","Publishers":[],"RunningFor":"25 seconds ago","Service":"builder","Size":"0B","State":"exited","Status":"Exited"}
{"Command":"\"/gdprapi -config /g…\"","CreatedAt":"2026-11-05 14:42:58 +0300 +03","Engine":"","ExitCode":0,"Health":"","ID":"gdprapi-2564","Image":"golang:1.26.10-alpine3.23","Labels":"com.mocker.compose.project=gdprapi-2564206480,com.mocker.compose.service=gdprapi","LocalVolumes":"0","Mounts":"","Name":"gdprapi-2564206480-gdprapi-1","Names":"gdprapi-2564206480-gdprapi-1","Networks":"","Ports":"127.0.0.1:65389-\u003e8080/tcp","Project":"gdprapi-2564206480","Publishers":[{"URL":"127.0.0.1","TargetPort":8080,"PublishedPort":65389,"Protocol":"tcp"}],"RunningFor":"22 seconds ago","Service":"gdprapi","Size":"0B","State":"running","Status":"Up"}
{"Command":"\"python /snowflake/s…\"","CreatedAt":"2026-11-05 14:41:40 +0300 +03","Engine":"","ExitCode":0,"Health":"","ID":"gdprapi-2564","Image":"677516718998.dkr.ecr.us-east-1.amazonaws.com/bigdata/fakesnow:v0.1.0","Labels":"com.mocker.compose.project=gdprapi-2564206480,com.mocker.compose.service=snowflake","LocalVolumes":"0","Mounts":"","Name":"gdprapi-2564206480-snowflake-1","Names":"gdprapi-2564206480-snowflake-1","Networks":"","Ports":"","Project":"gdprapi-2564206480","Publishers":[],"RunningFor":"About a minute ago","Service":"snowflake","Size":"0B","State":"running","Status":"Up"}
{"Command":"\"sh -c \\\"echo \u003chi\u003e \u0026\u0026…\"","CreatedAt":"2026-11-03 13:00:00 +0300 +03","Engine":"","ExitCode":0,"Health":"","ID":"0123456789ab","Image":"nginx:1.27","Labels":"a=1,b=2","LocalVolumes":"0","Mounts":"","Name":"zeta-web-1","Names":"zeta-web-1","Networks":"","Ports":"0.0.0.0:8080-8081-\u003e8080-8081/tcp, [::]:8080-\u003e8080/tcp, 9000/udp","Project":"zeta","Publishers":[{"URL":"0.0.0.0","TargetPort":8081,"PublishedPort":8081,"Protocol":"tcp"},{"URL":"0.0.0.0","TargetPort":8080,"PublishedPort":8080,"Protocol":"tcp"},{"URL":"::","TargetPort":8080,"PublishedPort":8080,"Protocol":"tcp"},{"URL":"","TargetPort":9000,"PublishedPort":0,"Protocol":"udp"}],"RunningFor":"2 days ago","Service":"web","Size":"0B","State":"exited","Status":"Exited"}
"""#),
        ("stack", #"raw"#, false, #"""
container_id: gdprapi-2564
image: golang:1.26.10-alpine3.23
command: "go build -ldflags -…"
created_at: 2026-11-05 14:42:55 +0300 +03
state: exited
status: Exited
names: gdprapi-2564206480-builder-1
labels:
ports:

container_id: gdprapi-2564
image: golang:1.26.10-alpine3.23
command: "/gdprapi -config /g…"
created_at: 2026-11-05 14:42:58 +0300 +03
state: running
status: Up
names: gdprapi-2564206480-gdprapi-1
labels: com.mocker.compose.project=gdprapi-2564206480,com.mocker.compose.service=gdprapi
ports: 127.0.0.1:65389->8080/tcp

container_id: gdprapi-2564
image: 677516718998.dkr.ecr.us-east-1.amazonaws.com/bigdata/fakesnow:v0.1.0
command: "python /snowflake/s…"
created_at: 2026-11-05 14:41:40 +0300 +03
state: running
status: Up
names: gdprapi-2564206480-snowflake-1
labels: com.mocker.compose.project=gdprapi-2564206480,com.mocker.compose.service=snowflake
ports:

container_id: 0123456789ab
image: nginx:1.27
command: "sh -c \"echo <hi> &&…"
created_at: 2026-11-03 13:00:00 +0300 +03
state: exited
status: Exited
names: zeta-web-1
labels: a=1,b=2
ports: 0.0.0.0:8080-8081->8080-8081/tcp, [::]:8080->8080/tcp, 9000/udp

"""#),
        ("stack", #"{{.Service}} {{.State}}"#, false, #"""
builder exited
gdprapi running
snowflake running
web exited
"""#),
        ("stack", #"table {{.Name}}\t{{.Health}}\t{{.Label "com.mocker.compose.service"}}"#, false, #"""
NAME                             <no value>   service
gdprapi-2564206480-builder-1                  
gdprapi-2564206480-gdprapi-1                  gdprapi
gdprapi-2564206480-snowflake-1                snowflake
zeta-web-1                                    
"""#),
        ("stack", #"{{json .Publishers}} {{.Publishers}}"#, false, #"""
[] []
[{"URL":"127.0.0.1","TargetPort":8080,"PublishedPort":65389,"Protocol":"tcp"}] [8080/tcp -> 127.0.0.1:65389]
[] []
[{"URL":"0.0.0.0","TargetPort":8081,"PublishedPort":8081,"Protocol":"tcp"},{"URL":"0.0.0.0","TargetPort":8080,"PublishedPort":8080,"Protocol":"tcp"},{"URL":"::","TargetPort":8080,"PublishedPort":8080,"Protocol":"tcp"},{"URL":"","TargetPort":9000,"PublishedPort":0,"Protocol":"udp"}] [8081/tcp -> 0.0.0.0:8081 8080/tcp -> 0.0.0.0:8080 8080/tcp -> [::]:8080 9000/udp -> :0]
"""#),
        ("stack", #"table {{.ID}}\t{{.Ports}}"#, false, #"""
CONTAINER ID   PORTS
gdprapi-2564   
gdprapi-2564   127.0.0.1:65389->8080/tcp
gdprapi-2564   
0123456789ab   0.0.0.0:8080-8081->8080-8081/tcp, [::]:8080->8080/tcp, 9000/udp
"""#),
        ("stack", #"{{.ID}} {{.Command}} {{.Names}}"#, true, #"""
gdprapi-2564206480-builder-1 "go build -ldflags -w -o gdprapi.linux ." gdprapi-2564206480-builder-1
gdprapi-2564206480-gdprapi-1 "/gdprapi -config /gdprapi.toml" gdprapi-2564206480-gdprapi-1
gdprapi-2564206480-snowflake-1 "python /snowflake/start.py" gdprapi-2564206480-snowflake-1
sha256:0123456789abcdef0123 "sh -c \"echo <hi> && sleep 1\"\tx" zeta-web-1
"""#),
        ("stack", #"{{.Service | upper}} {{lower .State}} {{truncate .Name 7}}{{pad .Service 1 1}}|{{title "hello world-x"}} {{split .Name "-"}} {{json .Name}} {{json .ExitCode}}"#, false, #"""
BUILDER exited gdprapi builder |Hello World-X [gdprapi 2564206480 builder 1] "gdprapi-2564206480-builder-1" 0
GDPRAPI running gdprapi gdprapi |Hello World-X [gdprapi 2564206480 gdprapi 1] "gdprapi-2564206480-gdprapi-1" 0
SNOWFLAKE running gdprapi snowflake |Hello World-X [gdprapi 2564206480 snowflake 1] "gdprapi-2564206480-snowflake-1" 0
WEB exited zeta-we web |Hello World-X [zeta web 1] "zeta-web-1" 0
"""#),
        ("stack", #"  {{.CreatedAt}} {{.Labels}} {{.Size}} {{.LocalVolumes}} [{{.Mounts}}] [{{.Networks}}] [{{.Engine}}] {{.Project}}  "#, false, #"""
2026-11-05 14:42:55 +0300 +03  0B 0 [] [] [] gdprapi-2564206480
2026-11-05 14:42:58 +0300 +03 com.mocker.compose.project=gdprapi-2564206480,com.mocker.compose.service=gdprapi 0B 0 [] [] [] gdprapi-2564206480
2026-11-05 14:41:40 +0300 +03 com.mocker.compose.project=gdprapi-2564206480,com.mocker.compose.service=snowflake 0B 0 [] [] [] gdprapi-2564206480
2026-11-03 13:00:00 +0300 +03 a=1,b=2 0B 0 [] [] [] zeta
"""#),
        ("stack", #"table {{.Service}}\t{{.Status}}\t{{pad .Health 1 0}}\t{{json .Name}}"#, false, #"""
SERVICE     STATUS    
builder     Exited              "gdprapi-2564206480-builder-1"
gdprapi     Up                  "gdprapi-2564206480-gdprapi-1"
snowflake   Up                  "gdprapi-2564206480-snowflake-1"
web         Exited              "zeta-web-1"
"""#),
        ("stack", #"{{- .Name -}} | {{/* a comment */}}{{.State}}"#, false, #"""
gdprapi-2564206480-builder-1| exited
gdprapi-2564206480-gdprapi-1| running
gdprapi-2564206480-snowflake-1| running
zeta-web-1| exited
"""#),
        ("empty", #"table"#, false, #"""
NAME      IMAGE     COMMAND   SERVICE   CREATED   STATUS    PORTS
"""#),
        ("empty", #"{{.Name}}"#, false, #"""
"""#),
        ("durations", #"table {{.Name}}\t{{.RunningFor}}"#, false, #"""
NAME         CREATED
d000000000   Less than a second ago
d000000001   1 second ago
d000000002   2 seconds ago
d000000059   59 seconds ago
d000000060   About a minute ago
d000000119   About a minute ago
d000000120   2 minutes ago
d000003599   59 minutes ago
d000003600   About an hour ago
d000005399   About an hour ago
d000005400   2 hours ago
d000170640   47 hours ago
d000172800   2 days ago
d001209599   2 weeks ago
d001209600   2 weeks ago
d005183999   2 months ago
d005184000   2 months ago
d063071999   1 years ago
d063072000   2 years ago
d094608000   3 years ago
"""#),
    ]
}
