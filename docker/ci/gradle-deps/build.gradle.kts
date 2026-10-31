plugins {
    antlr
    java
}

repositories {
    mavenCentral()
}

// cubrid-jdbc is left out: the engine build takes it from its cubrid-jdbc submodule.
dependencies {
    testImplementation("org.junit.jupiter:junit-jupiter:5.9.1")
    implementation("com.kohlschutter.junixsocket:junixsocket-core:2.8.3")
    implementation("com.kohlschutter.junixsocket:junixsocket-server:2.8.3")
    antlr("org.antlr:antlr4:4.9.3")
    implementation("org.apache.commons:commons-text:1.10.0")
    implementation("org.apache.commons:commons-collections4:4.4")
    implementation("org.apache.commons:commons-lang3:3.18.0")
    implementation("commons-io:commons-io:2.15.1")
    implementation("org.apache.commons:commons-compress:1.26.0")
    implementation("org.antlr:antlr4-runtime:4.9.3")
    implementation("io.netty:netty-buffer:4.1.115.Final")
}
