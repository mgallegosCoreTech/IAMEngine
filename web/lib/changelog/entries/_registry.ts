// Every entry file, one line each. Sorted by id so two PRs adding entries insert at
// DIFFERENT lines and git merges them without a conflict — the whole point of the split.
// Order here is irrelevant: index.ts sorts by date+time. Adding a file without adding it
// here would silently drop it from the log, so registry.test.ts fails on any mismatch.
export { entry as acceptedFailureCaseStatus } from "./accepted-failure-case-status";
export { entry as adAmbientAuthFirst } from "./ad-ambient-auth-first";
export { entry as adDcOptional } from "./ad-dc-optional";
export { entry as adMirrorByEmail } from "./ad-mirror-by-email";
export { entry as adStandaloneDomainSeparation } from "./ad-standalone-domain-separation";
export { entry as adSyncedAdoptOnly } from "./ad-synced-adopt-only";
export { entry as adsyncedAdoptSyncedAccount } from "./adsynced-adopt-synced-account";
export { entry as adSyncedGalHide } from "./ad-synced-gal-hide";
export { entry as adFolderTreePicker } from "./ad-folder-tree-picker";
export { entry as addDirectorySyncButton } from "./add-directory-sync-button";
export { entry as adhocStepsAboveCaseResolution } from "./adhoc-steps-above-case-resolution";
export { entry as adminAttentionModal } from "./admin-attention-modal";
export { entry as adobeConsoleAutoSetup } from "./adobe-console-auto-setup";
export { entry as adobeOrgIdAccountid } from "./adobe-org-id-accountid";
export { entry as agentRemoteBrowserInstall } from "./agent-remote-browser-install";
export { entry as agentRestartStatusVisible } from "./agent-restart-status-visible";
export { entry as agentUrlMigration } from "./agent-url-migration";
export { entry as agentUrlModalMergePrs } from "./agent-url-modal-merge-prs";
export { entry as agentsMigratedBadge4hWindow } from "./agents-migrated-badge-4h-window";
export { entry as auditActorProvenance } from "./audit-actor-provenance";
export { entry as auditAttributesDiscoveryToUser } from "./audit-attributes-discovery-to-user";
export { entry as autoUpdateStopsLooping } from "./auto-update-stops-looping";
export { entry as azureCutoverAgentRehoming } from "./azure-cutover-agent-rehoming";
export { entry as auditWatchedGraphAppPerms } from "./audit-watched-graph-app-perms";
export { entry as azureInventoryAndS1Roster } from "./azure-inventory-and-s1-roster";
export { entry as backupAzureRestoreDrill } from "./backup-azure-restore-drill";
export { entry as baypineRunFixesAdoptRetryArchive } from "./baypine-run-fixes-adopt-retry-archive";
export { entry as browserInstallSaysWhy } from "./browser-install-says-why";
export { entry as buildFromSystemsPreview } from "./build-from-systems-preview";
export { entry as calendarReviewerChangesExisting } from "./calendar-reviewer-changes-existing";
export { entry as calendarReviewerGrants } from "./calendar-reviewer-grants";
export { entry as caseDomainLockExplainsItself } from "./case-domain-lock-explains-itself";
export { entry as caseExitDryRun } from "./case-exit-dry-run";
export { entry as caseExtraGroups } from "./case-extra-groups";
export { entry as casePrerunPasswordReset } from "./case-prerun-password-reset";
export { entry as caseRequestedMailForwarding } from "./case-requested-mail-forwarding";
export { entry as caseRequestedSharedMailboxes } from "./case-requested-shared-mailboxes";
export { entry as casesAssignedToColumn } from "./cases-assigned-to-column";
export { entry as casesAssignedToServicenow } from "./cases-assigned-to-servicenow";
export { entry as casesEmptyM365autosetupJsonFilter } from "./cases-empty-m365autosetup-json-filter";
export { entry as casesV2AccessRules } from "./cases-v2-access-rules";
export { entry as changeActionGroundwork } from "./change-action-groundwork";
export { entry as changeAdLane } from "./change-ad-lane";
export { entry as changeApiRoutes } from "./change-api-routes";
export { entry as changeDeltaTypes } from "./change-delta-types";
export { entry as changeDiffEngine } from "./change-diff-engine";
export { entry as changeExchangeLane } from "./change-exchange-lane";
export { entry as changeGoogleLane } from "./change-google-lane";
export { entry as changeM365Lane } from "./change-m365-lane";
export { entry as changePlanner } from "./change-planner";
export { entry as changeRunner1740 } from "./change-runner-1740";
export { entry as changeService } from "./change-service";
export { entry as changeUiComponents } from "./change-ui-components";
export { entry as changeUiWired } from "./change-ui-wired";
export { entry as changelogOneFilePerEntry } from "./changelog-one-file-per-entry";
export { entry as changelogPage } from "./changelog-page";
export { entry as changelogTimes } from "./changelog-times";
export { entry as changelogTimesEastern } from "./changelog-times-eastern";
export { entry as changelogTimesEasternUtcFix } from "./changelog-times-eastern-utc-fix";
export { entry as chatAlertsWarningsAndMasterSwitch } from "./chat-alerts-warnings-and-master-switch";
export { entry as childModelingInheritance } from "./child-modeling-inheritance";
export { entry as childReplanParentFallback } from "./child-replan-parent-fallback";
export { entry as clientLifecycleRoles } from "./client-lifecycle-roles";
export { entry as clientsActionsMenu } from "./clients-actions-menu";
export { entry as cleanerCaseResolutionNotes } from "./cleaner-case-resolution-notes";
export { entry as concurrencyGovernor } from "./concurrency-governor";
export { entry as connectorBuilder } from "./connector-builder";
export { entry as connectorBrowserSessionAuth } from "./connector-browser-session-auth";
export { entry as connectorProbeAndHarHosts } from "./connector-probe-and-har-hosts";
export { entry as consistencyCheckCannotVerify } from "./consistency-check-cannot-verify";
export { entry as copyButtonsWorkOffTheHost } from "./copy-buttons-work-off-the-host";
export { entry as createSecretIdentitySubfolder } from "./create-secret-identity-subfolder";
export { entry as coreidSlugRedirect } from "./coreid-slug-redirect";
export { entry as coretelligentPostResetRestore } from "./coretelligent-post-reset-restore";
export { entry as credExpirySettings } from "./cred-expiry-settings";
export { entry as credPlatform } from "./cred-platform";
export { entry as cvpMailboxAuditing } from "./cvp-mailbox-auditing";
export { entry as defaultSharedMailboxAccess } from "./default-shared-mailbox-access";
export { entry as delineaSecretserverCloudCreateFix } from "./delinea-secretserver-cloud-create-fix";
export { entry as delineaTemplateByName } from "./delinea-template-by-name";
export { entry as delineaWriteFailManualModal } from "./delinea-write-fail-manual-modal";
export { entry as directorySyncAddsRunbookStep } from "./directory-sync-adds-runbook-step";
export { entry as directorySyncWaitsToFinish } from "./directory-sync-waits-to-finish";
export { entry as dismissWarningsOnADoneCase } from "./dismiss-warnings-on-a-done-case";
export { entry as documentsUploadRedlineProgress } from "./documents-upload-redline-progress";
export { entry as documentsVersionedInApp } from "./documents-versioned-in-app";
export { entry as easterEggs } from "./easter-eggs";
export { entry as editedFieldsRerunRules } from "./edited-fields-rerun-rules";
export { entry as egnyteApiPasswordGrant } from "./egnyte-api-password-grant";
export { entry as egnyteBrowserSetup } from "./egnyte-browser-setup";
export { entry as engineOptOutHardening } from "./engine-opt-out-hardening";
export { entry as engineOptOutParentInheritance } from "./engine-opt-out-parent-inheritance";
export { entry as exchangeDisconnectExportHotfix } from "./exchange-disconnect-export-hotfix";
export { entry as exchangeManagerName } from "./exchange-manager-name";
export { entry as exchangeRightsManageasapp } from "./exchange-rights-manageasapp";
export { entry as exoPinSelfheal } from "./exo-pin-selfheal";
export { entry as exoPinSurvivesSelfheal } from "./exo-pin-survives-selfheal";
export { entry as exoTenantIsolation } from "./exo-tenant-isolation";
export { entry as extraAccessIndicator } from "./extra-access-indicator";
export { entry as featureRequestNumbersAndAutoHide } from "./feature-request-numbers-and-auto-hide";
export { entry as featureRequestsImplementedTable } from "./feature-requests-implemented-table";
export { entry as featureRequestsMenuBadgeLiveCounts } from "./feature-requests-menu-badge-live-counts";
export { entry as featureRequestsOwnPage } from "./feature-requests-own-page";
export { entry as fleetAuditNamesNewlines } from "./fleet-audit-names-newlines";
export { entry as fleetAuditPermsAndLeakedSeats } from "./fleet-audit-perms-and-leaked-seats";
export { entry as fleetAuditPivotNames } from "./fleet-audit-pivot-names";
export { entry as fleetHealthDashboardAlerting } from "./fleet-health-dashboard-alerting";
export { entry as fleetReportRestrictedRouting } from "./fleet-report-restricted-routing";
export { entry as foundation } from "./foundation";
export { entry as frameworkSystemsAreChecklistSteps } from "./framework-systems-are-checklist-steps";
export { entry as goliveHardening } from "./golive-hardening";
export { entry as goliveReadinessPreflight } from "./golive-readiness-preflight";
export { entry as googleBackbonePasswordReset } from "./google-backbone-password-reset";
export { entry as googleCustomerIdValidation } from "./google-customer-id-validation";
export { entry as googleDelineaFieldNamesMatchTemplate } from "./google-delinea-field-names-match-template";
export { entry as googleKeyConverterTool } from "./google-key-converter-tool";
export { entry as googleKeyFileUpload } from "./google-key-file-upload";
export { entry as googleOauthDeheadUa } from "./google-oauth-dehead-ua";
export { entry as googleOauthErrorNamesTheBlock } from "./google-oauth-error-names-the-block";
export { entry as googleSetupReopenFormAfterFailure } from "./google-setup-reopen-form-after-failure";
export { entry as googleOauthRedirectCaptureFix } from "./google-oauth-redirect-capture-fix";
export { entry as googleKeyToolCreateDelinea } from "./google-key-tool-create-delinea";
export { entry as googleOauthOfflineGrant } from "./google-oauth-offline-grant";
export { entry as googleSigninWelcomeFalsePositive } from "./google-signin-welcome-falsepositive";
export { entry as googleWorkspaceAutoSetupOverview } from "./google-workspace-auto-setup-overview";
export { entry as gracefulDrainMaintenanceMode } from "./graceful-drain-maintenance-mode";
export { entry as graphSigninsModuleMissing } from "./graph-signins-module-missing";
export { entry as guidedApiSetup } from "./guided-api-setup";
export { entry as guidedSetupAutomatedAndSuggest } from "./guided-setup-automated-and-suggest";
export { entry as guidedSetupFullerInstructions } from "./guided-setup-fuller-instructions";
export { entry as guidedSetupSpanningPasteAndBrowserLabels } from "./guided-setup-spanning-paste-and-browser-labels";
export { entry as guidedSetupTestThenWrite } from "./guided-setup-test-then-write";
export { entry as guidedSetupWizardAndSuggestions } from "./guided-setup-wizard-and-suggestions";
export { entry as hideDryRunOption } from "./hide-dry-run-option";
export { entry as importClientsByCoreid } from "./import-clients-by-coreid";
export { entry as importDialogWidthDarkModeBlocks } from "./import-dialog-width-dark-mode-blocks";
export { entry as kbFetchPipeline } from "./kb-fetch-pipeline";
export { entry as knowbe4BrowserSetup } from "./knowbe4-browser-setup";
export { entry as llmModelAwareRequests } from "./llm-model-aware-requests";
export { entry as llmProviderApiVersionAndAsk } from "./llm-provider-api-version-and-ask";
export { entry as llmProviderAzureForm } from "./llm-provider-azure-form";
export { entry as locationGroupsPickerPrinters } from "./location-groups-picker-printers";
export { entry as m365AppAutoProvisionCore } from "./m365-app-auto-provision-core";
export { entry as m365AppDelineaWriteback } from "./m365-app-delinea-writeback";
export { entry as m365AttributeRules } from "./m365-attribute-rules";
export { entry as m365AutoSetupOrchestrationCore } from "./m365-auto-setup-orchestration-core";
export { entry as m365AutoSetupUsable } from "./m365-auto-setup-usable";
export { entry as m365LicenseDependencySelfheal } from "./m365-license-dependency-selfheal";
export { entry as m365SetupAutomaticallyOverview } from "./m365-setup-automatically-overview";
export { entry as m365AutosetupSurfacesDelineaId } from "./m365-autosetup-surfaces-delinea-id";
export { entry as m365CredsToIdentityServices } from "./m365-creds-to-identity-services";
export { entry as m365AutosetupWriteFailModal } from "./m365-autosetup-write-fail-modal";
export { entry as m365DevicecodeAuth } from "./m365-devicecode-auth";
export { entry as m365DevicecodeCopy } from "./m365-devicecode-copy";
export { entry as m365FleetPermissionReport } from "./m365-fleet-permission-report";
export { entry as m365PasswordResetPermission } from "./m365-password-reset-permission";
export { entry as m365PermProbeFlakyAndOptionalCaps } from "./m365-perm-probe-flaky-and-optional-caps";
export { entry as m365PermcheckMailboxParity } from "./m365-permcheck-mailbox-parity";
export { entry as m365ProvisionExchangeAppOnly } from "./m365-provision-exchange-app-only";
export { entry as m365SetupAutorecoverRunlog } from "./m365-setup-autorecover-runlog";
export { entry as m365SetupCertExchangeOptions } from "./m365-setup-cert-exchange-options";
export { entry as m365SetupAutowireLabel } from "./m365-setup-autowire-label";
export { entry as m365SetupCertUnit } from "./m365-setup-cert-unit";
export { entry as m365SetupGaRefModal } from "./m365-setup-ga-ref-modal";
export { entry as m365SetupPlaceholderSecretId } from "./m365-setup-placeholder-secret-id";
export { entry as m365SetupProgressModal } from "./m365-setup-progress-modal";
export { entry as m365SetupPropagationTolerance } from "./m365-setup-propagation-tolerance";
export { entry as m365SetupRecoveryCert } from "./m365-setup-recovery-cert";
export { entry as m365SetupSigninCallout } from "./m365-setup-signin-callout";
export { entry as m365SetupVaultSelfheal } from "./m365-setup-vault-selfheal";
export { entry as mailboxMirrorNamesSource } from "./mailbox-mirror-names-source";
export { entry as mailboxNotConvertedDecision } from "./mailbox-not-converted-decision";
export { entry as mailboxSizeDecisionClarity } from "./mailbox-size-decision-clarity";
export { entry as manualCaseNumbersAndFixStatus } from "./manual-case-numbers-and-fix-status";
export { entry as manualSetPasswordOption } from "./manual-set-password-option";
export { entry as mfaDefaultMethodRemovedLast } from "./mfa-default-method-removed-last";
export { entry as mimecastConntestAndSubfolderRequired } from "./mimecast-conntest-and-subfolder-required";
export { entry as mimecastConsolePhase2 } from "./mimecast-console-phase2";
export { entry as mimecastConsoleSigninSecretRef } from "./mimecast-console-signin-secret-ref";
export { entry as mimecastConsoleSigninTest } from "./mimecast-console-signin-test";
export { entry as mimecastConsoleUrlFix } from "./mimecast-console-url-fix";
export { entry as mimecastDocProductsPoc } from "./mimecast-doc-products-poc";
export { entry as modelFilesReadwritePerm } from "./model-files-readwrite-perm";
export { entry as moduleSetupGuidedVault } from "./module-setup-guided-vault";
export { entry as multipleMailboxDelegates } from "./multiple-mailbox-delegates";
export { entry as nicknamePersonaLane } from "./nickname-persona-lane";
export { entry as offboardAdminAccountSweep } from "./offboard-admin-account-sweep";
export { entry as offboardAlreadySharedMailbox } from "./offboard-already-shared-mailbox";
export { entry as offboardCaseRequestedDelegate } from "./offboard-case-requested-delegate";
export { entry as offboardClearsManagerInEntra } from "./offboard-clears-manager-in-entra";
export { entry as offboardCaseOutOfOffice } from "./offboard-case-out-of-office";
export { entry as offboardConvertBeforeLicense } from "./offboard-convert-before-license";
export { entry as offboardConvertByDefault } from "./offboard-convert-by-default";
export { entry as offboardHideFromGal } from "./offboard-hide-from-gal";
export { entry as offboardIdentityResolution } from "./offboard-identity-resolution";
export { entry as offboardLicenceFleetSweep } from "./offboard-licence-fleet-sweep";
export { entry as offboardLicenseAfterSharedConvert } from "./offboard-license-after-shared-convert";
export { entry as offboardManagerNotneededRunbook } from "./offboard-manager-notneeded-runbook";
export { entry as offboardOnedriveArchive } from "./offboard-onedrive-archive";
export { entry as offboardOnedriveDelegateAccess } from "./offboard-onedrive-delegate-access";
export { entry as offboardRemovesAdGroups } from "./offboard-removes-ad-groups";
export { entry as offboardRevokeMfaAndSessions } from "./offboard-revoke-mfa-and-sessions";
export { entry as offboardTargetPicker } from "./offboard-target-picker";
export { entry as onedriveArchiveSiteName } from "./onedrive-archive-site-name";
export { entry as offboardUnifiedGroupRemoval } from "./offboard-unified-group-removal";
export { entry as onedriveGrantRealError } from "./onedrive-grant-real-error";
export { entry as optionalCredEmptyLabel } from "./optional-cred-empty-label";
export { entry as passwordChangeAtFirstLoginOptional } from "./password-change-at-first-login-optional";
export { entry as passwordDialogControlsWork } from "./password-dialog-controls-work";
export { entry as passwordResetGuiFix } from "./password-reset-gui-fix";
export { entry as perContactIntakeRules } from "./per-contact-intake-rules";
export { entry as personaSystemMembership } from "./persona-system-membership";
export { entry as phoneRequestedRuleField } from "./phone-requested-rule-field";
export { entry as pr7Pr10Batch } from "./pr7-pr10-batch";
export { entry as proofpointHttpsSchemeWedge } from "./proofpoint-https-scheme-wedge";
export { entry as prsAnnouncesToChat } from "./prs-announces-to-chat";
export { entry as prsMergeMigrationsAndWorktreeRetire } from "./prs-merge-migrations-and-worktree-retire";
export { entry as readinessWiredUntestedClarity } from "./readiness-wired-untested-clarity";
export { entry as referenceDocsV2 } from "./reference-docs-v2";
export { entry as referenceDocsV3 } from "./reference-docs-v3";
export { entry as rehireAdoptsExistingAccount } from "./rehire-adopts-existing-account";
export { entry as requestedGroupsReachThePlan } from "./requested-groups-reach-the-plan";
export { entry as resetChildToParent } from "./reset-child-to-parent";
export { entry as rulesEditorRemoveSystem } from "./rules-editor-remove-system";
export { entry as runLogFixedLinesPopulate } from "./run-log-fixed-lines-populate";
export { entry as runLogFixedNoLongerBuriesARecurrence } from "./run-log-fixed-no-longer-buries-a-recurrence";
export { entry as runlogBulkCopy } from "./runlog-bulk-copy";
export { entry as runnerBundleByteStable } from "./runner-bundle-byte-stable";
export { entry as runnerGenerator } from "./runner-generator";
export { entry as runnerGraphSkewGuard } from "./runner-graph-skew-guard";
export { entry as runnerPoolOneBox } from "./runner-pool-one-box";
export { entry as runnerVersionStartupLog } from "./runner-version-startup-log";
export { entry as securityP0Runner } from "./security-p0-runner";
export { entry as selfHealWatchdog } from "./self-heal-watchdog";
export { entry as selfUpdateKeepsBrowserSidecar } from "./self-update-keeps-browser-sidecar";
export { entry as selfhealNeverImportsInProcess } from "./selfheal-never-imports-in-process";
export { entry as selfhealRestartCannotLoop } from "./selfheal-restart-cannot-loop";
export { entry as settingsDeploymentStatus } from "./settings-deployment-status";
export { entry as setupRunCancelButton } from "./setup-run-cancel-button";
export { entry as slackCatalogBuilt } from "./slack-catalog-built";
export { entry as smallMailboxesNotEmpty } from "./small-mailboxes-not-empty";
export { entry as slackConsoleBrowserSetup } from "./slack-console-browser-setup";
export { entry as sharepointFullcontrolUsedRole } from "./sharepoint-fullcontrol-used-role";
export { entry as sharepointGrantsOutOfProcess } from "./sharepoint-grants-out-of-process";
export { entry as sharepointMultipleDelegates } from "./sharepoint-multiple-delegates";
export { entry as sharepointOnedriveFullaccessGrant } from "./sharepoint-onedrive-fullaccess-grant";
export { entry as sixOneBackOfficeOnRequest } from "./six-one-back-office-on-request";
export { entry as singleStepClaimedFirst } from "./single-step-claimed-first";
export { entry as slackExecutorAndManualFlip } from "./slack-executor-and-manual-flip";
export { entry as soundEggs } from "./sound-eggs";
export { entry as spanningBrowserApiSetup } from "./spanning-browser-api-setup";
export { entry as spanningDestructiveDropsLicence } from "./spanning-destructive-drops-licence";
export { entry as spanningForceSyncCentralOnly } from "./spanning-force-sync-central-only";
export { entry as spanningGuidedSetupDerived } from "./spanning-guided-setup-derived";
export { entry as spanningForceSyncFixed } from "./spanning-force-sync-fixed";
export { entry as spanningForceSyncWorks } from "./spanning-force-sync-works";
export { entry as spanningHeadlessTokenHarvest } from "./spanning-headless-token-harvest";
export { entry as spanningLoginHiddenView } from "./spanning-login-hidden-view";
export { entry as spanningOtpBroker } from "./spanning-otp-broker";
export { entry as starwarsEgg } from "./starwars-egg";
export { entry as spanningPortalSecretSplit } from "./spanning-portal-secret-split";
export { entry as systemsEditorKb } from "./systems-editor-kb";
export { entry as tenFixHardeningBatch } from "./ten-fix-hardening-batch";
export { entry as unlicensedUserHoldsMimecastSpanning } from "./unlicensed-user-holds-mimecast-spanning";
export { entry as unmodeledStepsBecomeManual } from "./unmodeled-steps-become-manual";
export { entry as v2Offboarding } from "./v2-offboarding";
export { entry as v3MenusCollapsibleSections } from "./v3-menus-collapsible-sections";
export { entry as wedgedRunnerReportsItsJob } from "./wedged-runner-reports-its-job";
export { entry as zoomBrowserAutoSetup } from "./zoom-browser-auto-setup";
export { entry as zoomChunkRealCap } from "./zoom-chunk-real-cap";
export { entry as zoomSendSaysWhyItFailed } from "./zoom-send-says-why-it-failed";
export { entry as zoomSenderPaginationGuard } from "./zoom-sender-pagination-guard";
export { entry as m365SetupAutodetectFolder } from "./m365-setup-autodetect-folder";
export { entry as adConntestOptionalDcSecret } from "./ad-conntest-optional-dc-secret";
export { entry as featureRequestSendToChat } from "./feature-request-send-to-chat";
export { entry as locationGroupsLaneAware } from "./location-groups-lane-aware";
export { entry as guidedSetupLiveTestFeedback } from "./guided-setup-live-test-feedback";
export { entry as fleetSetupM365 } from "./fleet-setup-m365";
export { entry as fleetM365SelfGrant } from "./fleet-m365-self-grant";
export { entry as conntestNotNeededRows } from "./conntest-not-needed-rows";
export { entry as m365ProxyaddressConflictFeedback } from "./m365-proxyaddress-conflict-feedback";
export { entry as replanRederiveNeverrunMode } from "./replan-rederive-neverrun-mode";

export { entry as fleetAuditEscalationHolders } from "./fleet-audit-escalation-holders";
export { entry as adobeOnboardEmptyProfiles } from "./adobe-onboard-empty-profiles";
export { entry as exoMirrorBoundedTimeout } from "./exo-mirror-bounded-timeout";

export { entry as fleetM365SelfgrantOptional } from "./fleet-m365-selfgrant-optional";

export { entry as fleetM365CountFixSelfcorrectFilter } from "./fleet-m365-count-fix-selfcorrect-filter";

export { entry as fleetM365SkipsNoRunner } from "./fleet-m365-skips-no-runner";

export { entry as fleetM365StuckTestReaper } from "./fleet-m365-stuck-test-reaper";

export { entry as perAgentRunnerAuth } from "./per-agent-runner-auth";

export { entry as dbCopyTool } from "./db-copy-tool";
export { entry as fixEdgeCryptoBuildCrash } from "./fix-edge-crypto-build-crash";
export { entry as fixMigrateWorkingdir } from "./fix-migrate-workingdir";

export { entry as dbCopyConnectionForm } from "./db-copy-connection-form";

export { entry as dbCopySslmodeToggle } from "./db-copy-sslmode-toggle";

export { entry as dbCopyCrossVersionGuc } from "./db-copy-cross-version-guc";

export { entry as dbCopyFullCloneAndAudit } from "./db-copy-full-clone-and-audit";

export { entry as dbCopyDataOnlyIntoMigratedSchema } from "./db-copy-data-only-into-migrated-schema";

export { entry as delineaNeverVaultToRoot } from "./delinea-never-vault-to-root";
export { entry as dbCopyBuildSchemaButton } from "./db-copy-build-schema-button";

export { entry as auditFullDetailExpand } from "./audit-full-detail-expand";

export { entry as m365WritebackTemplateByName } from "./m365-writeback-template-by-name";

export { entry as connTestOptionalFlagSurvivesWire } from "./conn-test-optional-flag-survives-wire";

export { entry as pirateEgg } from "./pirate-egg";

export { entry as easterEggsPage } from "./easter-eggs-page";

export { entry as eggCatalogDemos } from "./egg-catalog-demos";

export { entry as tenNewEggs } from "./ten-new-eggs";

export { entry as anniversaryEgg } from "./anniversary-egg";

export { entry as locationsActiveFilterFixed } from "./locations-active-filter-fixed";

export { entry as restoreDrillSelfHeal } from "./restore-drill-self-heal";
export { entry as exoPinSaysWhy } from "./exo-pin-says-why";

export { entry as inflightMarkerPerAgent } from "./inflight-marker-per-agent";

export { entry as browserInstallSurvivesUpdate } from "./browser-install-survives-update";

export { entry as containerMigratesBeforeServing } from "./container-migrates-before-serving";

export { entry as browserInstallReasonCaptured } from "./browser-install-reason-captured";

export { entry as managerResolvedByEmail } from "./manager-resolved-by-email";

export { entry as systemConfigIntentGuard } from "./system-config-intent-guard";

export { entry as licenseHoldCoversMailboxSystems } from "./license-hold-covers-mailbox-systems";

export { entry as mfaDenialHintRanksCauses } from "./mfa-denial-hint-ranks-causes";

export { entry as passwordResetLetsEntraAnswer } from "./password-reset-lets-entra-answer";
export { entry as runnerAnchorsWorkingDirectory } from "./runner-anchors-working-directory";
export { entry as syncWaitActuallyWaits } from "./sync-wait-actually-waits";
export { entry as onedriveScaGrantActuallyRuns } from "./onedrive-sca-grant-actually-runs";
export { entry as teamsPhone } from "./teams-phone";
