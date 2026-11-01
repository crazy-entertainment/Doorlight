package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteControlSystemNodeScanTest {
    private data class Node(val id: Int, val depth: Int = 0)

    @Test
    fun broadNodeCannotReadMoreThanTheDiscoveryBudget() {
        var reads = 0
        var visits = 0
        val complete = RemoteControlSystemNodeScan.visit(
            windows = listOf(Node(0)),
            root = { ++reads; it },
            childCount = { if (it.depth == 0) 100_000 else 0 },
            child = { _, index -> ++reads; Node(index, 1) },
            visitNode = { ++visits },
        )
        assertTrue("root/child reads: $reads", reads <= RemoteControlSystemNodeScan.MAX_NODES)
        assertTrue(visits <= RemoteControlSystemNodeScan.MAX_NODES)
        assertFalse(complete)
    }

    @Test
    fun deepTreeReportsIncompleteWithoutReadingBeyondTheBudget() {
        var reads = 0
        var visits = 0
        val complete = RemoteControlSystemNodeScan.visit(
            windows = listOf(Node(0)),
            root = { ++reads; it },
            childCount = { if (it.depth < 100_000) 1 else 0 },
            child = { node, _ -> ++reads; Node(node.id + 1, node.depth + 1) },
            visitNode = { ++visits },
        )
        assertFalse("A partial scan cannot authorize its selected click target", complete)
        assertEquals(RemoteControlSystemNodeScan.MAX_NODES, reads)
        assertEquals(RemoteControlSystemNodeScan.MAX_NODES, visits)
    }

    @Test
    fun manyWindowsShareOneBudgetIncludingMissingRoots() {
        for (rootPresent in listOf(true, false)) {
            var reads = 0
            var visits = 0
            val complete = RemoteControlSystemNodeScan.visit(
                windows = 0..600,
                root = { ++reads; if (rootPresent) Node(it) else null },
                childCount = { 0 },
                child = { _: Node, _: Int -> error("No children") },
                visitNode = { ++visits },
            )
            assertTrue("window root reads: $reads", reads <= RemoteControlSystemNodeScan.MAX_NODES)
            assertEquals(if (rootPresent) reads else 0, visits)
            assertFalse(complete)
        }
    }

    @Test
    fun completeNormalTreesPreserveWindowAndBreadthFirstOrder() {
        val visited = mutableListOf<Int>()
        var reads = 0
        assertTrue(RemoteControlSystemNodeScan.visit(
            windows = listOf(Node(1), Node(10)),
            root = { ++reads; it },
            childCount = { if (it.depth == 0) 2 else 0 },
            child = { node, index -> ++reads; Node(node.id + index + 1, 1) },
            visitNode = { visited += it.id },
        ))
        assertEquals(listOf(1, 2, 3, 10, 11, 12), visited)
        assertEquals(6, reads)
    }

    @Test
    fun exactBudgetCompletesAndAnEmptyScanDoesNoReads() {
        for (count in listOf(0, RemoteControlSystemNodeScan.MAX_NODES)) {
            var reads = 0
            var visits = 0
            assertTrue(RemoteControlSystemNodeScan.visit(
                windows = 0 until count,
                root = { ++reads; Node(it) },
                childCount = { 0 },
                child = { _: Node, _: Int -> error("No children") },
                visitNode = { ++visits },
            ))
            assertEquals(count, reads)
            assertEquals(count, visits)
        }
    }

    @Test
    fun missingChildrenStillConsumeTheSharedBudget() {
        var reads = 0
        assertFalse(RemoteControlSystemNodeScan.visit(
            windows = listOf(Node(0)),
            root = { ++reads; it },
            childCount = { Int.MAX_VALUE },
            child = { _: Node, _: Int -> ++reads; null },
            visitNode = {},
        ))
        assertEquals(RemoteControlSystemNodeScan.MAX_NODES, reads)
    }

    @Test
    fun failedOrInvalidNodeQueriesReportIncomplete() {
        assertFalse(RemoteControlSystemNodeScan.visit(
            windows = listOf(Node(0)),
            root = { it },
            childCount = { throw IllegalStateException("synthetic stale node") },
            child = { _: Node, _: Int -> error("No child read after failure") },
            visitNode = {},
        ))
        assertFalse(RemoteControlSystemNodeScan.visit(
            windows = listOf(Node(0)),
            root = { it },
            childCount = { -1 },
            child = { _: Node, _: Int -> error("Invalid count has no children") },
            visitNode = {},
        ))
    }
}
