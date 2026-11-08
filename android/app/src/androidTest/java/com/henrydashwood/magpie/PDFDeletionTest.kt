package com.henrydashwood.magpie

import androidx.activity.compose.setContent
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import com.henrydashwood.magpie.ui.PDFDeletion
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class PDFDeletionTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun cancelledConfirmationCannotDeleteAfterReopeningTheSameDocument() {
        var calls = 0
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent { PDFDeletion("Field notes") { calls++ } }
            }
            lateinit var open: () -> Boolean
            compose.onNodeWithText("Delete PDF").performSemanticsAction(SemanticsActions.OnClick) { click ->
                open = click
                click()
            }
            lateinit var cancel: () -> Boolean
            compose.onNodeWithText("Cancel").performSemanticsAction(SemanticsActions.OnClick) { cancel = it }
            val confirm = compose.onNode(hasText("Delete PDF") and hasAnyAncestor(isDialog()))
            confirm.performSemanticsAction(SemanticsActions.OnClick) { oldConfirm ->
                cancel()
                open()
                oldConfirm()
                cancel()
            }
            compose.runOnIdle { assertEquals(0, calls) }
            confirm.assertIsDisplayed().performClick()
            compose.runOnIdle { assertEquals(1, calls) }
            compose.onNodeWithText("Delete PDF?").assertDoesNotExist()
        }
    }

    @Test fun doubleConfirmationSendsOneDeletionAndFailureAllowsOneRetry() {
        val reply = CompletableDeferred<Unit>()
        var calls = 0
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    PDFDeletion("Field notes") {
                        calls++
                        if (!reply.isCompleted) {
                            reply.await()
                            error("Delete failed")
                        }
                    }
                }
            }
            compose.onNodeWithText("Delete PDF").performClick()
            val confirm = compose.onNode(hasText("Delete PDF") and hasAnyAncestor(isDialog()))
            confirm.performSemanticsAction(SemanticsActions.OnClick) { click -> click(); click() }
            compose.runOnIdle { assertEquals(1, calls) }
            reply.complete(Unit)
            compose.onNode(hasText("Delete failed") and hasAnyAncestor(isDialog())).assertIsDisplayed()
            confirm.performClick()
            compose.onNodeWithText("Delete PDF?").assertDoesNotExist()
            compose.runOnIdle { assertEquals(2, calls) }
        }
    }
}
