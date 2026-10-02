package com.example.vaultaot.startup.files;

import java.util.Map;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Secrets from files + AOT: secrets are rendered to files before the app starts; no Vault client. */
@SpringBootApplication
@RestController
public class FileSecretsApplication {

    private static final Log logger = LogFactory.getLog(FileSecretsApplication.class);

    // No default: startup fails if the secret didn't arrive.
    private final String dbPassword;

    FileSecretsApplication(@Value("${db.password}") String dbPassword) {
        this.dbPassword = dbPassword;
    }

    public static void main(String[] args) {
        SpringApplication.run(FileSecretsApplication.class, args);
    }

    @Bean
    ApplicationRunner reportSecret() {
        return args -> logger.info("db.password loaded=" + !dbPassword.isBlank());
    }

    @GetMapping("/")
    Map<String, Boolean> status() {
        return Map.of("dbPasswordLoaded", !dbPassword.isBlank());
    }
}
