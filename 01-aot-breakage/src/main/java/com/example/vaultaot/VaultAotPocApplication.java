package com.example.vaultaot;

import org.springframework.aot.AotDetector;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.cloud.vault.config.VaultProperties;
import org.springframework.context.ApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.core.env.Environment;
import org.springframework.vault.core.VaultTemplate;

@SpringBootApplication
public class VaultAotPocApplication {

    public static void main(String[] args) {
        SpringApplication.run(VaultAotPocApplication.class, args);
    }

    /** Bean whose existence depends on a flag stored in Vault - AOT decides this at build time. */
    @Bean
    @ConditionalOnProperty(name = "feature.audit.enabled", havingValue = "true")
    AuditService auditService() {
        return new AuditService();
    }

    @Bean
    CommandLineRunner report(ApplicationContext ctx, Environment env,
                             @Value("${db.password:<NOT LOADED>}") String dbPassword) {
        return args -> {
            System.out.println("==== vault-aot-poc report ====");
            System.out.println("AOT mode active        : " + AotDetector.useGeneratedArtifacts());
            System.out.println("db.password (Vault)    : " + dbPassword);
            System.out.println("feature.audit.enabled  : " + env.getProperty("feature.audit.enabled"));
            System.out.println("AuditService bean      : " + count(ctx, AuditService.class));
            System.out.println("VaultTemplate beans    : " + count(ctx, VaultTemplate.class));
            System.out.println("VaultProperties beans  : " + count(ctx, VaultProperties.class));
            System.out.println("==============================");
        };
    }

    private static int count(ApplicationContext ctx, Class<?> type) {
        return ctx.getBeanNamesForType(type).length;
    }

    static class AuditService {
    }
}
