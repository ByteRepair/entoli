package io.github.yiannis128.agent_chat

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.webkit.MimeTypeMap
import io.flutter.util.PathUtils
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

// Entoli's workspaces in the Files app, and in any picker that asks for a file
// or a folder — the way a cloud drive puts itself there. What the user picks is
// what gets read: the system grants the chosen app a URI, so nothing here is
// exposed to an app the user did not point at it.
//
// Read-only. A workspace is where the agent's output lands and this is the way
// out to whatever reads it; files come the other way through the share sheet,
// which already has a page for asking which workspace they belong in. Adding
// writes means FLAG_SUPPORTS_CREATE plus createDocument/deleteDocument, not a
// change to any of this.
//
// Nothing of Dart is running when this is queried — the Files app starts the
// process by asking — so the layout is read off the disk here. What has to
// agree with `AppConfig` is the shape of it, and `workspaceDepth` with
// `projectOf` is the whole of that.
class WorkspaceProvider : DocumentsProvider() {
    override fun onCreate() = true

    override fun queryRoots(projection: Array<String>?): Cursor {
        val cursor = MatrixCursor(ROOT_COLUMNS)
        cursor.newRow().apply {
            add(Root.COLUMN_ROOT_ID, "workspaces")
            // The default project, which is the data directory itself — so the
            // top of this tree is the top of that one, and a named project is a
            // folder in it exactly as it is on disk.
            add(Root.COLUMN_DOCUMENT_ID, PROJECT)
            add(Root.COLUMN_TITLE, app.applicationInfo.loadLabel(app.packageManager).toString())
            add(Root.COLUMN_SUMMARY, "Workspaces")
            add(Root.COLUMN_FLAGS, Root.FLAG_LOCAL_ONLY or Root.FLAG_SUPPORTS_IS_CHILD)
            add(Root.COLUMN_ICON, R.mipmap.ic_cookie)
        }
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<String>?): Cursor {
        val cursor = MatrixCursor(DOCUMENT_COLUMNS)
        if (documentId.startsWith(PROJECT)) {
            cursor.addProject(projectOf(documentId))
        } else {
            val found = locate(documentId)
            cursor.addFile(documentId, found.file, nameOf(found))
        }
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<String>?,
        sortOrder: String?,
    ): Cursor {
        val cursor = MatrixCursor(DOCUMENT_COLUMNS)
        if (parentDocumentId.startsWith(PROJECT)) {
            cursor.addProjectChildren(projectOf(parentDocumentId))
            return cursor
        }
        val parent = locate(parentDocumentId)
        parent.file.listFiles()?.sortedBy { it.name.lowercase() }?.forEach { child ->
            // Resolved rather than trusted: the agent's own commands run in
            // these directories, so a link out of one is something it can have
            // left behind, and following it would hand out the data directory.
            if (contains(parent.workspace, child.canonicalFile)) {
                cursor.addFile("$parentDocumentId/${child.name}", child, child.name)
            }
        }
        return cursor
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        if (ParcelFileDescriptor.parseMode(mode) != ParcelFileDescriptor.MODE_READ_ONLY) {
            throw UnsupportedOperationException("Entoli's workspaces are read-only here")
        }
        return ParcelFileDescriptor.open(
            locate(documentId).file,
            ParcelFileDescriptor.MODE_READ_ONLY,
        )
    }

    // What FLAG_SUPPORTS_IS_CHILD promises, and what a picker asking for a whole
    // folder needs answered.
    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean = when {
        parentDocumentId == PROJECT -> documentId != PROJECT
        parentDocumentId.startsWith(PROJECT) ->
            documentId.startsWith("projects/${parentDocumentId.substring(PROJECT.length)}/")
        else -> documentId.startsWith("$parentDocumentId/")
    }

    /** A document id resolved to a file, and the workspace it had to stay in. */
    private class Found(val segments: List<String>, val depth: Int, val file: File, val workspace: File)

    /**
     * A document id that is not a project is a path relative to the data
     * directory, and only the workspaces are reachable through one: the file
     * has to resolve inside `[projects/<name>/]workspace` or
     * `[projects/<name>/]chats/<id>/workspace`, and anything else is not there.
     */
    private fun locate(documentId: String): Found {
        val segments = documentId.split('/')
        if (segments.any { it.isEmpty() || it == "." || it == ".." }) throw notFound(documentId)
        val depth = workspaceDepth(segments) ?: throw notFound(documentId)
        val workspace = File(dataDir, segments.take(depth).joinToString(File.separator)).canonicalFile
        val file = File(dataDir, segments.joinToString(File.separator)).canonicalFile
        if (!contains(workspace, file)) throw notFound(documentId)
        return Found(segments, depth, file, workspace)
    }

    /**
     * The project a project document id names — empty for the default one. It
     * has to be one directory under `projects/`, which is `AppConfig.projectDir`'s
     * rule and is here for the same reason: everything scoped to a project is a
     * path built through it.
     */
    private fun projectOf(documentId: String): String {
        val name = documentId.substring(PROJECT.length)
        if (name.isNotEmpty() && !isProjectName(name)) throw notFound(documentId)
        return name
    }

    /**
     * How many leading segments of a document id are the workspace it is in, or
     * null if it names no workspace at all. This is the whole of what the tree
     * exposes; `resources/`, `subagents/` and the conversation itself are not
     * in it, and neither is anything beside a project's `chats/`.
     */
    private fun workspaceDepth(segments: List<String>): Int? {
        val start = if (segments.firstOrNull() == "projects") 2 else 0
        return when (segments.getOrNull(start)) {
            "workspace" -> start + 1
            "chats" -> if (segments.getOrNull(start + 2) == "workspace") start + 3 else null
            else -> null
        }
    }

    private fun MatrixCursor.addProjectChildren(project: String) {
        val dir = if (project.isEmpty()) dataDir else File(dataDir, "projects/$project")
        val prefix = if (project.isEmpty()) "" else "projects/$project/"

        File(dir, "workspace").takeIf { it.isDirectory }?.let {
            addFile("${prefix}workspace", it, SHARED)
        }
        File(dir, "chats").listFiles()?.sorted()?.forEach { chat ->
            val workspace = File(chat, "workspace")
            if (workspace.isDirectory) {
                addFile("${prefix}chats/${chat.name}/workspace", workspace, chatTitle(chat))
            }
        }
        // Only the default project has any: `projects/` is a directory in it,
        // and a project of its own would be one nested in another.
        if (project.isEmpty()) {
            File(dataDir, "projects").listFiles()?.sorted()
                ?.filter { it.isDirectory && isProjectName(it.name) }
                ?.forEach { addProject(it.name) }
        }
    }

    private fun MatrixCursor.addProject(project: String) {
        newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, PROJECT + project)
            // `defaultProjectLabel`, in lib/domain/project.dart.
            add(Document.COLUMN_DISPLAY_NAME, project.ifEmpty { "Default" })
            add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR)
            add(Document.COLUMN_FLAGS, 0)
        }
    }

    private fun MatrixCursor.addFile(documentId: String, file: File, name: String) {
        newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, documentId)
            add(Document.COLUMN_DISPLAY_NAME, name)
            add(Document.COLUMN_MIME_TYPE, mimeOf(file))
            add(Document.COLUMN_LAST_MODIFIED, file.lastModified())
            add(Document.COLUMN_FLAGS, 0)
            if (file.isFile) add(Document.COLUMN_SIZE, file.length())
        }
    }

    /**
     * Every workspace is a directory called `workspace`, so one is named after
     * whatever owns it: a chat by its title, a project's shared one by the word
     * the app already uses for it.
     */
    private fun nameOf(found: Found): String {
        if (found.segments.size != found.depth) return found.file.name
        val chats = found.segments.size >= 3 && found.segments[found.segments.size - 3] == "chats"
        if (!chats) return SHARED
        return chatTitle(File(dataDir, found.segments.dropLast(1).joinToString(File.separator)))
    }

    /**
     * The chat's own name. Read out of `state.json` here rather than handed
     * over by Dart, which is not running: a document written by a rename is
     * either the old one whole or the new one, so there is no half of it to
     * read. Untitled, it falls back to the id, which is what its directory is
     * called.
     */
    private fun chatTitle(chatDir: File): String = try {
        JSONObject(File(chatDir, "state.json").readText())
            .optString("title").ifBlank { chatDir.name }
    } catch (e: Exception) {
        chatDir.name
    }

    // `isProjectName`, in lib/domain/project.dart: one directory under
    // `projects/`, and not a hidden one — so a stray `.git` beside them is not
    // a project with nothing in it, and `..` is not a project at all.
    private fun isProjectName(name: String) =
        name.isNotEmpty() && !name.startsWith(".") && !name.contains('/')

    private fun mimeOf(file: File): String = when {
        file.isDirectory -> Document.MIME_TYPE_DIR
        else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
            ?: "application/octet-stream"
    }

    private fun contains(dir: File, file: File) =
        file == dir || file.path.startsWith(dir.path + File.separator)

    private fun notFound(documentId: String) =
        FileNotFoundException("No workspace document at $documentId")

    // The same call path_provider's getApplicationDocumentsDirectory makes, so
    // this is where `platformDataDir` put the data directory rather than a
    // guess at where it might be.
    private val dataDir: File
        get() = File(PathUtils.getDataDirectory(app), "agent-chat")

    private val app get() = context!!

    private companion object {
        // A document id is either a project — ":" for the default one and
        // ":<name>" for a named one — or a path relative to the data directory,
        // which is what every file and folder in a workspace is. Nothing can be
        // read as both: a project name is never empty, and a real path always
        // starts `workspace`, `chats` or `projects`.
        const val PROJECT = ":"

        // What the workspace explorer calls a workspace whose owner is already
        // named by what it is sitting under.
        const val SHARED = "Workspace"

        val ROOT_COLUMNS = arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY,
            Root.COLUMN_FLAGS,
            Root.COLUMN_ICON,
        )

        // The projection a query asks for is ignored, deliberately: a cursor may
        // carry more columns than were asked for, and MatrixCursor throws on an
        // `add` naming a column the projection left out.
        val DOCUMENT_COLUMNS = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
            Document.COLUMN_SIZE,
        )
    }
}
