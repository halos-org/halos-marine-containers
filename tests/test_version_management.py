"""Tests for version management functionality."""

import tempfile
from pathlib import Path


class TestVersionFile:
    """Tests for VERSION file validation."""

    def test_version_file_exists(self):
        """Test that VERSION file exists at repository root."""
        version_file = Path(__file__).parent.parent / "VERSION"
        assert version_file.exists(), "VERSION file must exist at repository root"

    def test_version_file_contains_valid_semver(self):
        """Test that VERSION file contains a valid semantic version."""
        version_file = Path(__file__).parent.parent / "VERSION"
        version = version_file.read_text().strip()

        # Basic semver format: MAJOR.MINOR.PATCH
        parts = version.split(".")
        assert len(parts) == 3, (
            f"Version must be MAJOR.MINOR.PATCH format, got: {version}"
        )

        # Each part must be a non-negative integer
        for part in parts:
            assert part.isdigit(), f"Version parts must be integers, got: {version}"
            assert int(part) >= 0, f"Version parts must be non-negative, got: {version}"

    def test_version_file_single_line(self):
        """Test that VERSION file contains only a single line."""
        version_file = Path(__file__).parent.parent / "VERSION"
        content = version_file.read_text()
        lines = content.strip().split("\n")
        assert len(lines) == 1, "VERSION file should contain exactly one line"


class TestChangelogParsing:
    """Tests for debian/changelog parsing."""

    def test_parse_store_changelog_version(self):
        """Test parsing version from store/debian/changelog."""
        changelog_file = Path(__file__).parent.parent / "store" / "debian" / "changelog"

        # Read first line
        first_line = changelog_file.read_text().split("\n")[0]

        # Expected format: package-name (version-revision) distribution; urgency=level
        # Extract version between parentheses
        import re

        match = re.search(r"\(([^)]+)\)", first_line)
        assert match, f"Could not parse version from changelog: {first_line}"

        full_version = match.group(1)
        version = full_version.split("-")[0]  # Strip Debian revision

        # Validate it's a semver
        parts = version.split(".")
        assert len(parts) == 3, f"Parsed version should be semver format: {version}"

    def test_changelog_has_proper_format(self):
        """Test that changelog follows Debian format."""
        changelog_file = Path(__file__).parent.parent / "store" / "debian" / "changelog"
        first_line = changelog_file.read_text().split("\n")[0]

        # Must match: package-name (version) distribution; urgency=level
        import re

        pattern = r"^[\w-]+ \([^)]+\) \w+; urgency=\w+$"
        assert re.match(pattern, first_line), (
            f"Changelog first line doesn't match Debian format: {first_line}"
        )


class TestAppVersionParsing:
    """Tests for app metadata.yaml version parsing."""

    def test_all_apps_have_version_field(self):
        """Test that all apps have a version field in metadata.yaml."""
        import yaml

        apps_dir = Path(__file__).parent.parent / "apps"
        metadata_files = list(apps_dir.glob("*/metadata.yaml"))

        assert len(metadata_files) > 0, "No app metadata files found"

        for metadata_file in metadata_files:
            with open(metadata_file) as f:
                data = yaml.safe_load(f)

            app_name = metadata_file.parent.name
            assert "version" in data, f"App {app_name} missing 'version' field"
            assert data["version"], f"App {app_name} has empty version"

    def test_app_versions_are_valid_format(self):
        """Test that app versions follow expected format (semver-debian or date-based)."""
        import re

        import yaml

        apps_dir = Path(__file__).parent.parent / "apps"

        for metadata_file in apps_dir.glob("*/metadata.yaml"):
            with open(metadata_file) as f:
                data = yaml.safe_load(f)

            app_name = metadata_file.parent.name
            version = data["version"]

            # Expected formats:
            # - Semver: X.Y.Z or X.Y.Z-N (e.g., 2.17.2-1)
            # - Date-based: YYYYMMDD-N (e.g., 20240520-1)
            semver_pattern = r"^\d+\.\d+\.\d+(-\d+)?$"
            date_pattern = r"^\d{8}-\d+$"

            is_valid = re.match(semver_pattern, version) or re.match(
                date_pattern, version
            )
            assert is_valid, (
                f"App {app_name} has invalid version format: {version} "
                f"(expected semver like '2.17.2-1' or date-based like '20240520-1')"
            )


class TestVersionBumpCalculations:
    """Tests for version bump logic."""

    def test_patch_bump(self):
        """Test patch version bump (0.1.0 -> 0.1.1)."""
        current = "0.1.0"
        major, minor, patch = current.split(".")
        patch = str(int(patch) + 1)
        expected = f"{major}.{minor}.{patch}"
        assert expected == "0.1.1"

    def test_minor_bump(self):
        """Test minor version bump (0.1.5 -> 0.2.0)."""
        current = "0.1.5"
        major, minor, patch = current.split(".")
        minor = str(int(minor) + 1)
        patch = "0"
        expected = f"{major}.{minor}.{patch}"
        assert expected == "0.2.0"

    def test_major_bump(self):
        """Test major version bump (0.2.5 -> 1.0.0)."""
        current = "0.2.5"
        major, minor, patch = current.split(".")
        major = str(int(major) + 1)
        minor = "0"
        patch = "0"
        expected = f"{major}.{minor}.{patch}"
        assert expected == "1.0.0"

    def test_bump_from_multi_digit(self):
        """Test bumping versions with multi-digit components."""
        # Patch: 1.10.99 -> 1.10.100
        current = "1.10.99"
        major, minor, patch = current.split(".")
        patch = str(int(patch) + 1)
        expected = f"{major}.{minor}.{patch}"
        assert expected == "1.10.100"

        # Minor: 1.99.5 -> 1.100.0
        current = "1.99.5"
        major, minor, patch = current.split(".")
        minor = str(int(minor) + 1)
        patch = "0"
        expected = f"{major}.{minor}.{patch}"
        assert expected == "1.100.0"


class TestChangelogManipulation:
    """Tests for changelog prepending logic."""

    def test_prepend_changelog_entry(self):
        """Test prepending a new entry to changelog."""
        # Create a temporary changelog
        with tempfile.NamedTemporaryFile(
            mode="w", delete=False, suffix=".changelog"
        ) as f:
            temp_changelog = f.name
            f.write("""test-package (0.1.0-1) stable; urgency=medium

  * Initial release

 -- Test User <test@example.com>  Mon, 01 Jan 2024 12:00:00 +0000
""")

        try:
            # Prepend new entry
            new_entry = """test-package (0.2.0-1) stable; urgency=medium

  * Version bump to 0.2.0

 -- Test User <test@example.com>  Mon, 02 Jan 2024 12:00:00 +0000

"""

            # Read existing content
            with open(temp_changelog, "r") as f:
                old_content = f.read()

            # Write new entry + old content
            with open(temp_changelog, "w") as f:
                f.write(new_entry + old_content)

            # Verify the result
            with open(temp_changelog, "r") as f:
                lines = f.readlines()

            # First line should be the new version
            assert "0.2.0-1" in lines[0]
            # Old version should still be present
            content = "".join(lines)
            assert "0.1.0-1" in content

        finally:
            Path(temp_changelog).unlink()


class TestBumpversionConfig:
    """Tests for .bumpversion.cfg configuration."""

    def test_bumpversion_config_exists(self):
        """Test that .bumpversion.cfg exists."""
        config_file = Path(__file__).parent.parent / ".bumpversion.cfg"
        assert config_file.exists(), ".bumpversion.cfg must exist at repository root"

    def test_bumpversion_config_has_version_file(self):
        """Test that .bumpversion.cfg references VERSION file."""
        config_file = Path(__file__).parent.parent / ".bumpversion.cfg"
        content = config_file.read_text()

        assert "[bumpversion:file:VERSION]" in content, (
            ".bumpversion.cfg must have [bumpversion:file:VERSION] section"
        )

    def test_bumpversion_config_no_auto_tag(self):
        """Test that bumpversion is configured to not auto-tag."""
        config_file = Path(__file__).parent.parent / ".bumpversion.cfg"
        content = config_file.read_text()

        # Should have tag = False
        assert "tag = False" in content or "tag=False" in content, (
            ".bumpversion.cfg should have 'tag = False'"
        )


class TestGitHubWorkflows:
    """Tests for GitHub workflow configuration."""

    def test_main_workflow_exists(self):
        """Test that main workflow exists."""
        workflow = Path(__file__).parent.parent / ".github" / "workflows" / "main.yml"
        assert workflow.exists(), ".github/workflows/main.yml must exist"

    def test_pr_workflow_exists(self):
        """Test that PR workflow exists."""
        workflow = Path(__file__).parent.parent / ".github" / "workflows" / "pr.yml"
        assert workflow.exists(), ".github/workflows/pr.yml must exist"

    def test_release_workflow_exists(self):
        """Test that release workflow exists."""
        workflow = (
            Path(__file__).parent.parent / ".github" / "workflows" / "release.yml"
        )
        assert workflow.exists(), ".github/workflows/release.yml must exist"

    def test_calculate_revision_script_exists(self):
        """Test that calculate-revision.sh script exists."""
        script = (
            Path(__file__).parent.parent
            / ".github"
            / "scripts"
            / "calculate-revision.sh"
        )
        assert script.exists(), ".github/scripts/calculate-revision.sh must exist"

    def test_calculate_revision_script_is_executable(self):
        """Test that calculate-revision.sh script is executable."""
        script = (
            Path(__file__).parent.parent
            / ".github"
            / "scripts"
            / "calculate-revision.sh"
        )
        import stat

        assert script.stat().st_mode & stat.S_IXUSR, (
            "calculate-revision.sh should be executable"
        )
