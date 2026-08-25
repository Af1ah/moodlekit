# =============================================================================
# MoodleKit Tenant Caddy Route: {{SLUG}}
# Domain: {{DOMAIN}} | Upstream: {{UPSTREAM}}
# =============================================================================

http://{{DOMAIN}}, https://{{DOMAIN}} {
    import moodle_site {{UPSTREAM}} {{WEB_ROOT}} {{CONTAINER_ROOT}}
}
