```mermaid
graph TD;
    subgraph worker05
        application-manager-1
        application-manager-ui-865d74bdf6-5gffp
        authorization-server-979785576-qngsw
        cnf-monitor-ui-647d7d6597-snc22
        cnf-monitoring-event-broker-678b8664c7-2dnzr
        cnf-monitoring-fault-5b7488b5b8-gx76f
        cnf-monitoring-operation-bff-77b54bfb4-bbws4
        cnf-monitoring-operation-service-855f495d9f-6hpr4
        cnf-monitoring-performance-6797d7f764-ts84t
        kafka-2
        mariadb-galera-0
        mariadb-monitoring-galera-0
        maxscale-c7976b544-8rr77
        monitoring-maxscale-6fbbb89965-ml2k2
        nfvo-cnf-helm-client-76948478cc-sg7wr
    end
    
    subgraph worker06
        application-manager-2
        application-manager-ui-865d74bdf6-bd2w7
        authorization-server-979785576-vcb42
        cnf-monitor-ui-647d7d6597-4pdhl
        cnf-monitoring-cache-service-9bf467c99-2kl7j
        cnf-monitoring-event-broker-678b8664c7-62225
        cnf-monitoring-fault-5b7488b5b8-btgz7
        cnf-monitoring-operation-bff-77b54bfb4-4slqk
        cnf-monitoring-operation-service-855f495d9f-trl8t
        cnf-monitoring-performance-6797d7f764-qkkwd
        kafka-1
        mariadb-galera-2
        mariadb-monitoring-galera-1
        maxscale-c7976b544-dsfrc
        monitoring-maxscale-6fbbb89965-fwwr9
        nfvo-cnf-file-manager-0
        nfvo-cnf-helm-client-76948478cc-vkx4g
    end
    
    subgraph worker07
        application-manager-0
        application-manager-repository-5794f65f5b-9hjzm
        application-manager-ui-865d74bdf6-t6mrk
        authorization-server-979785576-7242n
        cnf-monitor-ui-647d7d6597-6k8h6
        cnf-monitoring-cache-service-9bf467c99-vtcjh
        cnf-monitoring-event-broker-678b8664c7-hp5vh
        cnf-monitoring-fault-5b7488b5b8-2ldj6
        cnf-monitoring-operation-bff-77b54bfb4-ck5pk
        cnf-monitoring-operation-service-855f495d9f-7fgsj
        cnf-monitoring-performance-6797d7f764-6p9wv
        kafka-0
        mariadb-galera-1
        mariadb-monitoring-galera-2
        maxscale-c7976b544-5t58r
        monitoring-maxscale-6fbbb89965-ktkmm
        nfvo-cnf-helm-client-76948478cc-f9wsp
    end
