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

// The workspaces in the Files app and in every picker that asks for a file or a
// folder. See "The workspaces in the Files app" in CLAUDE.md.
//
// Queried with no Flutter engine running — the Files app starts the process by
// asking — so the layout `AppConfig` composes is read off the disk here, and
// `workspaceDepth` with `projectOf` is the whole of that agreement.
class WorkspaceProvider : DocumentsProvider() {
    override fun onCreate() = true

    override fun queryRoots(projection: Array<String>?): Cursor {
        val cursor = MatrixCursor(ROOT_COLUMNS)
        val info = app.applicationInfo
        cursor.newRow().apply {
            add(Root.COLUMN_ROOT_ID, "workspaces")
            // The default project, which is the data directory itself.
            add(Root.COLUMN_DOCUMENT_ID, PROJECT)
            add(Root.COLUMN_TITLE, info.loadLabel(app.packageManager).toString())
            add(Root.COLUMN_SUMMARY, "Workspaces")
            add(Root.COLUMN_FLAGS, Root.FLAG_LOCAL_ONLY or Root.FLAG_SUPPORTS_IS_CHILD)
            // `<application android:icon>`, so this does not follow the user's
            // icon setting: a root is the app's, like AgentService's.
            add(Root.COLUMN_ICON, info.icon)
        }
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<String>?): Cursor {
        val cursor = MatrixCursor(DOCUMENT_COLUMNS)
        if (documentId.startsWith(PROJECT)) {
            cursor.addProject(projectOf(documentId))
            return cursor
        }
        val found = locate(documentId)
        val name = if (found.file == found.workspace) workspaceName(found.file) else found.file.name
        cursor.addFile(documentId, found.file, name)
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
        parent.file.listFiles()?.sortedWith(BY_NAME)?.forEach { child ->
            // Resolved rather than trusted: the agent's own commands run in
            // these directories, so a link out of one is something it can have
            // been told to leave behind.
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

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean = when {
        parentDocumentId == PROJECT -> documentId != PROJECT
        parentDocumentId.startsWith(PROJECT) ->
            documentId.startsWith(prefixOf(projectOf(parentDocumentId)))
        else -> documentId.startsWith("$parentDocumentId/")
    }

    private class Found(val file: File, val workspace: File)

    /**
     * Only the workspaces are reachable: a document id has to name one before
     * anything under it resolves, and has to still be inside it once every link
     * in it has been followed.
     */
    private fun locate(documentId: String): Found {
        val segments = documentId.split('/')
        if (segments.any { it.isEmpty() || it == "." || it == ".." }) throw notFound(documentId)
        val depth = workspaceDepth(segments) ?: throw notFound(documentId)
        val file = File(dataDir, segments.joinToString(File.separator)).canonicalFile
        val workspace = if (depth == segments.size) file else {
            File(dataDir, segments.take(depth).joinToString(File.separator)).canonicalFile
        }
        if (!contains(workspace, file)) throw notFound(documentId)
        return Found(file, workspace)
    }

    /**
     * The project a project document id names, empty for the default one. Held
     * to `AppConfig.projectDir`'s rule of one directory under `projects/`,
     * because a tree grant lets the app holding it compose ids of its own: `:..`
     * is one that arrives rather than one that was handed out.
     */
    private fun projectOf(documentId: String): String {
        val name = documentId.substring(PROJECT.length)
        if (name.isNotEmpty() && !isProjectName(name)) throw notFound(documentId)
        return name
    }

    /**
     * How many leading segments of a document id are the workspace it is in, or
     * null if it names none — so `resources/`, `subagents/` and the conversation
     * itself are not in the tree and cannot be asked for.
     */
    private fun workspaceDepth(segments: List<String>): Int? {
        val start = if (segments.firstOrNull() == "projects") 2 else 0
        return when (segments.getOrNull(start)) {
            "workspace" -> start + 1
            "chats" -> if (segments.getOrNull(start + 2) == "workspace") start + 3 else null
            else -> null
        }
    }

    private fun prefixOf(project: String) = if (project.isEmpty()) "" else "projects/$project/"

    private fun MatrixCursor.addProjectChildren(project: String) {
        val dir = if (project.isEmpty()) dataDir else File(dataDir, "projects/$project")
        val prefix = prefixOf(project)

        File(dir, "workspace").takeIf { it.isDirectory }?.let {
            addFile("${prefix}workspace", it, workspaceName(it))
        }
        File(dir, "chats").listFiles()?.sortedWith(BY_NAME)?.forEach { chat ->
            val workspace = File(chat, "workspace")
            if (workspace.isDirectory) {
                addFile("${prefix}chats/${chat.name}/workspace", workspace, workspaceName(workspace))
            }
        }
        // Only the default project has any: `projects/` is a directory in it,
        // and a project of its own would be one nested in another.
        if (project.isEmpty()) {
            File(dataDir, "projects").listFiles()?.sortedWith(BY_NAME)
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

    // Every workspace is a directory called `workspace`, so one is named after
    // whatever owns it: a chat by its title, a project's shared one by the word
    // the explorer uses.
    private fun workspaceName(workspace: File): String {
        val owner = workspace.parentFile ?: return "Workspace"
        return if (owner.parentFile?.name == "chats") chatTitle(owner) else "Workspace"
    }

    // Read behind the app's back, which is safe for the reason the documents are
    // written through a rename: there is no half-written `state.json` to catch.
    private fun chatTitle(chatDir: File): String = try {
        JSONObject(File(chatDir, "state.json").readText())
            .optString("title").ifBlank { chatDir.name }
    } catch (e: Exception) {
        chatDir.name
    }

    // `isProjectName`, in lib/domain/project.dart.
    private fun isProjectName(name: String) =
        name.isNotEmpty() && !name.startsWith(".") && !name.contains('/')

    // `viewerMime`, in lib/data/mime.dart: octet-stream throws away the one fact
    // that decides whether anything opens the file at all, so an unrecognised
    // one is offered as text, which is what most of a workspace is.
    private fun mimeOf(file: File): String = when {
        file.isDirectory -> Document.MIME_TYPE_DIR
        else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
            ?: "text/plain"
    }

    private fun contains(dir: File, file: File) =
        file == dir || file.path.startsWith(dir.path + File.separator)

    private fun notFound(documentId: String) =
        FileNotFoundException("No workspace document at $documentId")

    // The call path_provider's getApplicationDocumentsDirectory makes, so this
    // is where `platformDataDir` put the data directory rather than a guess at
    // it. Lazy, not eager: a provider is constructed during process start, and
    // nothing about this belongs there.
    private val dataDir by lazy { File(PathUtils.getDataDirectory(app), "agent-chat") }

    private val app get() = context!!

    private companion object {
        // A document id is either a project — ":" for the default one and
        // ":<name>" for a named one — or a path relative to the data directory,
        // which is what every file and folder in a workspace is. Nothing can be
        // read as both: a project name is never empty, and a real path always
        // starts `workspace`, `chats` or `projects`.
        const val PROJECT = ":"

        // `listWorkspace`'s order, in lib/domain/workspace.dart, minus the
        // folders-first half: DocumentsUI re-sorts by whatever the user picked,
        // so a second stat per row to group them buys nothing.
        val BY_NAME: Comparator<File> = compareBy(String.CASE_INSENSITIVE_ORDER) { it.name }

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
